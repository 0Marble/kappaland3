const std = @import("std");
const App = @import("App.zig");
const Game = @import("Game.zig");
const Chunk = @import("Chunk.zig");
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const MemoryUsage = @import("util.zig").MemoryUsage;
const Block = @import("Block.zig");
const cond_capture = @import("util.zig").cond_capture;

const logger = std.log.scoped(.chunk_manager);

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

chunk_pool: std.heap.MemoryPool(Chunk),
chunks: std.AutoArrayHashMapUnmanaged(Chunk.Coords, *Chunk),
current_min: Chunk.Coords,
current_max: Chunk.Coords,

gpas: []Gpa,
shared_gpa: Gpa,
shared_temp_arena: std.heap.ArenaAllocator,

threads: []std.Thread,
mutex: std.Thread.Mutex,
cond: std.Thread.Condition,
is_running: bool,

cmd_pool: std.heap.MemoryPool(Command),
cmd_queue: std.DoublyLinkedList,
queue_size: usize,
subtasks: std.ArrayList(SubTask),
// the difference from subtasks.items.len is that this is updated after a task is completed
// while len is updated when the task gets picked up
subtasks_left: usize,

built_meshes: std.ArrayList(*Chunk),
chunks_to_mesh: std.AutoArrayHashMapUnmanaged(Chunk.Coords, void),

const ChunkManager = @This();
const Instance = struct {
    var instance: ChunkManager = undefined;
};

pub const Options = struct {
    thread_cnt: ?usize = null,
};

pub fn init(options: Options) !*ChunkManager {
    const self = instance();
    const thread_cnt = options.thread_cnt orelse try std.Thread.getCpuCount();

    self.* = .{
        .chunks = .empty,
        .current_min = @splat(0),
        .current_max = @splat(0),
        .chunk_pool = .init(App.gpa()),
        .gpas = try App.gpa().alloc(Gpa, thread_cnt),
        .threads = try App.gpa().alloc(std.Thread, thread_cnt),
        .shared_gpa = .init,
        .shared_temp_arena = undefined,
        .mutex = .{},
        .cond = .{},
        .is_running = true,
        .built_meshes = .empty,
        .cmd_pool = .init(App.gpa()),
        .cmd_queue = .{},
        .queue_size = 0,
        .subtasks = .empty,
        .subtasks_left = 0,
        .chunks_to_mesh = .empty,
    };
    self.shared_temp_arena = .init(self.shared_gpa.allocator());

    for (self.threads, self.gpas) |*t, *g| {
        g.* = .init;
        t.* = try std.Thread.spawn(.{}, worker, .{ self, g.allocator() });
    }

    return self;
}

pub fn deinit(self: *ChunkManager) void {
    self.mutex.lock();
    self.is_running = false;
    self.mutex.unlock();
    self.cond.broadcast();

    for (self.threads) |t| t.join();
    for (self.gpas) |*g| _ = g.deinit();
    App.gpa().free(self.threads);
    App.gpa().free(self.gpas);

    self.chunks_to_mesh.deinit(App.gpa());
    self.chunks.deinit(App.gpa());
    self.subtasks.deinit(App.gpa());
    self.built_meshes.deinit(self.shared_gpa.allocator());
    self.chunk_pool.deinit();
    self.cmd_pool.deinit();
    self.shared_temp_arena.deinit();
    _ = self.shared_gpa.deinit();
}

pub fn on_imgui(self: *ChunkManager) !void {
    try App.gui().add_to_frame(ChunkManager, "Debug", self, on_imgui_impl, @src());
}

fn on_imgui_impl(self: *ChunkManager) !void {
    const cur_cmd = if (self.cmd_queue.first) |cmd|
        std.meta.activeTag(Command.from_link(cmd).body)
    else
        null;

    const str = try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        \\Chunks:
        \\    active: {d} {}...{}
        \\    work:   {d}:{d} ({?})
        \\    meshes: {d}:{d}
        \\    shared_mem: {f}
    ,
        .{
            self.chunks.count(),
            self.current_min,
            self.current_max,
            self.queue_size,
            self.subtasks_left,
            cur_cmd,
            self.chunks_to_mesh.count(),
            self.built_meshes.items.len,
            MemoryUsage.from_bytes(self.shared_gpa.total_requested_bytes),
        },
        0,
    );
    c.igText("%s", @as(c_str, @ptrCast(str)));

    for (self.gpas, 0..) |*g, i| {
        const mem_str = try std.fmt.allocPrintSentinel(
            App.frame_alloc(),
            "    thread {d}: {f}",
            .{ i + 1, MemoryUsage.from_bytes(g.total_requested_bytes) },
            0,
        );
        c.igText("%s", @as(c_str, @ptrCast(mem_str)));
    }
}

pub fn process(self: *ChunkManager) !void {
    self.mutex.lock();
    defer {
        self.mutex.unlock();
        self.cond.broadcast();
    }
    try self.process_impl();

    for (self.built_meshes.items) |chunk| {
        try Game.instance().block_renderer.upload_chunk_mesh(chunk);
        chunk.state = .ready;
    }

    self.built_meshes.clearRetainingCapacity();
    _ = self.shared_temp_arena.reset(.retain_capacity);
}

fn process_impl(self: *ChunkManager) !void {
    const cur = if (self.cmd_queue.first) |link|
        Command.from_link(link)
    else blk: {
        if (self.chunks_to_mesh.count() == 0) return;
        const cmd: *Command = try self.cmd_pool.create();
        cmd.* = .{ .link = .{}, .body = .mesh_chunks, .started = false };
        self.cmd_queue.prepend(&cmd.link);
        self.queue_size += 1;
        break :blk cmd;
    };

    switch (cur.body) {
        .set_block => |x| {
            const chunk_coords = Chunk.world_to_chunk(x[0]);
            _ = self.cmd_queue.popFirst();
            defer self.cmd_pool.destroy(cur);
            const chunk = self.get_chunk(chunk_coords) orelse return;
            chunk.set(Chunk.world_to_block(x[0]), x[1]);
            self.queue_size -= 1;
        },

        .load_region => |x| {
            if (!cur.started) {
                std.debug.assert(self.subtasks.items.len == 0);
                std.debug.assert(self.subtasks_left == 0);

                cur.started = true;

                const size: @Vector(3, usize) = @intCast(x[1] - x[0]);
                var to_remove = std.ArrayList(Chunk.Coords).empty;
                defer to_remove.deinit(App.frame_alloc());
                for (self.chunks.keys()) |coords| {
                    if (@reduce(.And, coords >= x[0]) and @reduce(.And, coords <= x[1]))
                        continue;
                    try to_remove.append(App.frame_alloc(), coords);
                }
                for (to_remove.items) |coords| {
                    const old = self.chunks.fetchSwapRemove(coords).?;
                    self.chunk_pool.destroy(old.value);
                    try Game.instance().block_renderer.destroy_chunk_mesh(coords);
                }

                for (0..size[0] + 1) |i| {
                    for (0..size[1] + 1) |j| {
                        for (0..size[2] + 1) |k| {
                            const coords = x[0] +
                                @as(Chunk.Coords, @intCast(@Vector(3, usize){ i, j, k }));
                            const entry = try self.chunks.getOrPut(App.gpa(), coords);
                            if (entry.found_existing) continue;

                            const chunk = try self.chunk_pool.create();
                            chunk.init(coords);
                            entry.value_ptr.* = chunk;
                            try self.subtasks.append(
                                App.gpa(),
                                .{ .coords = coords, .kind = .load_region },
                            );
                            try self.chunks_to_mesh.put(App.gpa(), chunk.coords, {});
                            for (Chunk.Neighbours(3).deltas) |d| {
                                try self.chunks_to_mesh.put(App.gpa(), chunk.coords + d, {});
                            }
                        }
                    }
                }

                self.subtasks_left = self.subtasks.items.len;
                self.current_min = x[0];
                self.current_max = x[1];
            }

            if (self.subtasks_left == 0) {
                _ = self.cmd_queue.popFirst();
                self.cmd_pool.destroy(cur);
                self.queue_size -= 1;
            }
        },

        .mesh_chunks => {
            if (!cur.started) {
                std.debug.assert(self.subtasks.items.len == 0);
                std.debug.assert(self.subtasks_left == 0);

                var to_remove = std.ArrayList(Chunk.Coords).empty;
                for (self.chunks_to_mesh.keys()) |coords| {
                    if (@reduce(.Or, coords < self.current_min) or
                        @reduce(.Or, coords > self.current_max) or
                        !self.chunks.contains(coords))
                    {
                        try to_remove.append(App.frame_alloc(), coords);
                        continue;
                    }

                    try to_remove.append(App.frame_alloc(), coords);
                    try self.subtasks.append(
                        App.gpa(),
                        .{ .coords = coords, .kind = .mesh_chunks },
                    );
                    self.subtasks_left += 1;
                }

                for (to_remove.items) |coords| {
                    _ = self.chunks_to_mesh.swapRemove(coords);
                }
                cur.started = true;
            }

            if (self.subtasks_left == 0) {
                _ = self.cmd_queue.popFirst();
                self.cmd_pool.destroy(cur);
                self.queue_size -= 1;
            }
        },
    }
}

pub fn get_chunk(self: *ChunkManager, coords: Chunk.Coords) ?*Chunk {
    return self.chunks.get(coords);
}

pub fn load_region(self: *ChunkManager, min: Chunk.Coords, max: Chunk.Coords) !void {
    if (@reduce(.And, min == self.current_min) and @reduce(.And, max == self.current_max)) {
        return;
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    const cmd = try self.cmd_pool.create();
    cmd.* = Command{
        .started = false,
        .link = .{},
        .body = .{ .load_region = .{ min, max } },
    };

    if (cond_capture(
        self.cmd_queue.first != self.cmd_queue.last,
        self.cmd_queue.last,
    )) |last_link| {
        const cur_last = Command.from_link(last_link);
        if (cur_last.body == .load_region) {
            _ = self.cmd_queue.pop();
            self.queue_size -= 1;
        }
    }

    self.cmd_queue.append(&cmd.link);
    self.queue_size += 1;
}

pub fn set_block(self: *ChunkManager, coords: Chunk.Coords, block: Block) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const chunk_coords = Chunk.world_to_chunk(coords);
    var chunks_to_remesh: std.StaticBitSet(27) = .initEmpty();

    var immediate = true;
    for (Chunk.Neighbours(3).deltas) |d| {
        const neighbour_block_chunk_coords = Chunk.world_to_chunk(d + coords);
        const relative_idx = Chunk.Neighbours(3).neighbour_index(
            chunk_coords,
            neighbour_block_chunk_coords,
        );

        if (self.get_chunk(neighbour_block_chunk_coords)) |chunk| {
            chunks_to_remesh.set(relative_idx);
            if (chunk.state != .ready) immediate = false;
        } else immediate = false;
    }

    if (immediate) {
        const chunk = self.get_chunk(chunk_coords).?;
        chunk.set(Chunk.world_to_block(coords), block);

        var it = chunks_to_remesh.iterator(.{});
        while (it.next()) |idx| {
            const remeshed = self.get_chunk(chunk_coords + Chunk.Neighbours(3).deltas[idx]).?;
            try remeshed.build_mesh(self.shared_temp_arena.allocator());

            try self.built_meshes.append(self.shared_gpa.allocator(), remeshed);
        }
        return;
    }
    std.debug.panic("todo", .{});

    // const cmd: *Command = try self.cmd_pool.create();
    // cmd.* = .{
    //     .started = false,
    //     .link = .{},
    //     .body = .{ .set_block = .{ coords, block } },
    // };
    // self.cmd_queue.append(&cmd.link);
    // self.queue_size += 1;
    //
    // var it = chunks_to_remesh.iterator(.{});
    // while (it.next()) |idx| {
    //     try self.chunks_to_mesh.put(
    //         App.gpa(),
    //         chunk_coords + Chunk.Neighbours(3).deltas[idx],
    //         {},
    //     );
    // }
}

pub fn instance() *ChunkManager {
    return &Instance.instance;
}

const Command = struct {
    link: std.DoublyLinkedList.Node,
    body: Body,
    started: bool,

    const Body = union(enum) {
        load_region: struct { Chunk.Coords, Chunk.Coords },
        mesh_chunks: void,
        set_block: struct { Chunk.Coords, Block },
    };

    fn from_link(link: *std.DoublyLinkedList.Node) *Command {
        return @alignCast(@fieldParentPtr("link", link));
    }
};

fn worker(self: *ChunkManager, gpa: std.mem.Allocator) void {
    const tid = std.Thread.getCurrentId();
    logger.info("{*}: [Thread {d}] started", .{ self, tid });

    self.mutex.lock();
    defer self.mutex.unlock();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    while (true) {
        while (self.subtasks.pop()) |task| {
            logger.debug(
                "{*}: [Thread {d}]: picked up task {s}@{}",
                .{ self, tid, @tagName(task.kind), task.coords },
            );
            if (!self.is_running) break;

            self.mutex.unlock();
            defer {
                self.mutex.lock();
                self.subtasks_left -= 1;
            }

            switch (task.kind) {
                .set_block => unreachable,
                .load_region => {
                    const chunk = self.get_chunk(task.coords).?;
                    chunk.generate();
                },
                .mesh_chunks => {
                    _ = scratch.reset(.retain_capacity);
                    const chunk = self.get_chunk(task.coords).?;
                    chunk.build_mesh(scratch.allocator()) catch |err| {
                        logger.err(
                            "{*}: [Thread {d}]: could not build mesh {}: {}",
                            .{ self, tid, task.coords, err },
                        );
                        continue;
                    };

                    self.mutex.lock();
                    defer self.mutex.unlock();

                    chunk.move_mesh_from_thread_memory(
                        self.shared_temp_arena.allocator(),
                    ) catch |err| {
                        logger.err(
                            "{*}: [Thread {d}]: couldnt dupe mesh {}: {}",
                            .{ self, tid, task.coords, err },
                        );
                        continue;
                    };
                    self.built_meshes.append(self.shared_gpa.allocator(), chunk) catch |err| {
                        logger.err(
                            "{*}: [Thread {d}]: couldnt dupe mesh {}: {}",
                            .{ self, tid, task.coords, err },
                        );
                        continue;
                    };
                },
            }
        }

        if (self.is_running) {
            self.cond.wait(&self.mutex);
        } else break;
    }

    logger.info("{*}: [Thread {d}] joined", .{ self, tid });
}

const SubTask = struct {
    coords: Chunk.Coords,
    kind: std.meta.Tag(Command.Body),
};
