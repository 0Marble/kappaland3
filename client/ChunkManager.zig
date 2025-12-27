const std = @import("std");
const App = @import("App.zig");
const Game = @import("Game.zig");
const Chunk = @import("Chunk.zig");
const ChunkMesh = @import("ChunkMesh.zig");
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const MemoryUsage = @import("util.zig").MemoryUsage;
const Block = @import("Block.zig");

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

meshes_to_apply: std.ArrayList(ChunkMesh),

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
        .meshes_to_apply = .empty,
        .cmd_pool = .init(App.gpa()),
        .cmd_queue = .{},
        .queue_size = 0,
        .subtasks = .empty,
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

    self.chunks.deinit(App.gpa());
    self.subtasks.deinit(App.gpa());
    self.meshes_to_apply.deinit(self.shared_gpa.allocator());
    self.chunk_pool.deinit();
    self.cmd_pool.deinit();
    self.shared_temp_arena.deinit();
    _ = self.shared_gpa.deinit();
}

pub fn on_imgui(self: *ChunkManager) !void {
    try App.gui().add_to_frame(ChunkManager, "Debug", self, on_imgui_impl, @src());
}

fn on_imgui_impl(self: *ChunkManager) !void {
    const str = try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        \\Chunks:
        \\    active: {d}
        \\    work:   {d}:{d}
    ,
        .{
            self.chunks.count(),
            self.queue_size,
            self.subtasks.items.len,
        },
        0,
    );
    c.igText("%s", @as(c_str, @ptrCast(str)));
}

pub fn process(self: *ChunkManager) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.process_impl();
}

fn process_impl(self: *ChunkManager) !void {
    const cur = Command.from_link(self.cmd_queue.first orelse return);
    switch (cur.body) {
        .set_block => |x| {
            const chunk_coords = Chunk.world_to_chunk(x[0]);
            _ = self.cmd_queue.pop();
            defer self.cmd_pool.destroy(cur);

            const chunk = self.get_chunk(chunk_coords) orelse return;

            chunk.set(Chunk.world_to_block(x[0]), x[1]);

            const min = @max(Chunk.Coords{ -1, -1, -1 } + chunk_coords, self.current_min);
            const max = @min(Chunk.Coords{ 1, 1, 1 } + chunk_coords, self.current_max);
            const cmd: *Command = try self.cmd_pool.create();
            cmd.* = .{
                .body = .{ .mesh_region = .{ min, max } },
                .link = .{},
                .started = false,
            };
            self.cmd_queue.prepend(&cmd.link);
            try self.process_impl();
        },

        .load_region => |x| {
            if (!cur.started) {
                std.debug.assert(self.subtasks.items.len == 0);
                cur.started = true;

                const size: @Vector(3, usize) = @intCast(x[1] - x[0]);
                for (0..size[0] + 1) |i| {
                    for (0..size[1] + 1) |j| {
                        for (0..size[2] + 1) |k| {
                            const coords = x[0] +
                                @as(Chunk.Coords, @intCast(@Vector(3, usize){ i, j, k }));
                            try self.subtasks.append(App.gpa(), .{ .coords = coords });
                        }
                    }
                }

                self.current_min = x[0];
                self.current_max = x[1];
                self.cond.signal();
            }

            if (self.subtasks.items.len == 0) {
                _ = self.cmd_queue.popFirst();
                self.cmd_pool.destroy(cur);

                const cmd: *Command = try self.cmd_pool.create();
                cmd.* = .{
                    .body = .{ .mesh_region = x },
                    .link = .{},
                    .started = false,
                };
                self.cmd_queue.prepend(&cmd.link);
            }
        },

        .mesh_region => |x| {
            if (!cur.started) {
                std.debug.assert(self.subtasks.items.len == 0);
                cur.started = true;

                const size: @Vector(3, usize) = @intCast(x[1] - x[0]);
                for (0..size[0] + 1) |i| {
                    for (0..size[1] + 1) |j| {
                        for (0..size[2] + 1) |k| {
                            const coords = x[0] +
                                @as(Chunk.Coords, @intCast(@Vector(3, usize){ i, j, k }));
                            try self.subtasks.append(App.gpa(), .{ .coords = coords });
                        }
                    }
                }
                self.cond.signal();
            }

            for (self.meshes_to_apply.items) |mesh| {
                try Game.instance().renderer.upload_chunk_mesh(mesh);
            }

            self.meshes_to_apply.clearRetainingCapacity();
            _ = self.shared_temp_arena.reset(.retain_capacity);

            if (self.subtasks.items.len == 0) {
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
    self.mutex.lock();
    defer self.mutex.unlock();

    const size: @Vector(3, usize) = @intCast(max - min);
    for (0..size[0] + 1) |i| {
        for (0..size[1] + 1) |j| {
            for (0..size[2] + 1) |k| {
                const coords = min +
                    @as(Chunk.Coords, @intCast(@Vector(3, usize){ i, j, k }));
                const entry = try self.chunks.getOrPut(App.gpa(), coords);
                if (entry.found_existing) continue;

                const chunk: *Chunk = try self.chunk_pool.create();
                chunk.init(coords);
                entry.value_ptr.* = chunk;
            }
        }
    }

    const cmd: *Command = try self.cmd_pool.create();
    cmd.* = .{
        .started = false,
        .link = .{},
        .body = .{ .load_region = .{ min, max } },
    };
    self.cmd_queue.append(&cmd.link);
    self.queue_size += 1;
}

pub fn set_block(self: *ChunkManager, coords: Chunk.Coords, block: Block.Id) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const cmd: *Command = try self.cmd_pool.create();
    cmd.* = .{
        .started = false,
        .link = .{},
        .body = .{ .set_block = .{ coords, block } },
    };
    self.cmd_queue.append(&cmd.link);
    self.queue_size += 1;
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
        mesh_region: struct { Chunk.Coords, Chunk.Coords },
        set_block: struct { Chunk.Coords, Block.Id },
    };

    fn from_link(link: *std.DoublyLinkedList.Node) *Command {
        return @alignCast(@fieldParentPtr("link", link));
    }
};

fn worker(self: *ChunkManager, gpa: std.mem.Allocator) void {
    const tid = std.Thread.getCurrentId();
    std.log.info("{*}: [Thread {d}] started", .{ self, tid });

    self.mutex.lock();
    defer self.mutex.unlock();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    while (true) {
        if (self.cmd_queue.first) |link| {
            const cmd: *Command = Command.from_link(link);
            while (self.subtasks.pop()) |task| {
                self.mutex.unlock();
                defer self.mutex.lock();

                switch (cmd.body) {
                    .set_block => unreachable,
                    .load_region => {
                        const chunk = self.get_chunk(task.coords).?;
                        chunk.generate();
                    },
                    .mesh_region => {
                        _ = scratch.reset(.retain_capacity);
                        const chunk = self.get_chunk(task.coords).?;
                        const mesh = ChunkMesh.build(chunk, scratch.allocator()) catch |err| {
                            std.log.err(
                                "{*}: [Thread {d}]: could not build mesh {}: {}",
                                .{ self, tid, task.coords, err },
                            );
                            continue;
                        };

                        self.mutex.lock();
                        defer self.mutex.unlock();

                        const duped = mesh.dupe(self.shared_temp_arena.allocator()) catch |err| {
                            std.log.err(
                                "{*}: [Thread {d}]: couldnt dupe mesh {}: {}",
                                .{ self, tid, task.coords, err },
                            );
                            continue;
                        };
                        self.meshes_to_apply.append(self.shared_gpa.allocator(), duped) catch |err| {
                            std.log.err(
                                "{*}: [Thread {d}]: couldnt dupe mesh {}: {}",
                                .{ self, tid, task.coords, err },
                            );
                            continue;
                        };
                    },
                }
            }
        }

        if (self.is_running) {
            self.cond.wait(&self.mutex);
        } else break;
    }

    std.log.info("{*}: [Thread {d}] joined", .{ self, tid });
}

const SubTask = struct {
    coords: Chunk.Coords,
};
