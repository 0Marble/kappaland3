const Chunk = @import("Chunk.zig");
const std = @import("std");
const World = @import("../World.zig");
const logger = std.log.scoped(.chunk_manager);
const Block = @import("../Block.zig");
const Coords = World.Coords;
const App = @import("../App.zig");
const util = @import("../util.zig");
const c = @import("../c.zig").c;
const c_str = @import("../c.zig").c_str;
const CHUNK_SIZE = Chunk.CHUNK_SIZE;

//*self: world.gpa

world: *World,
main_tid: std.Thread.Id,
threads: []std.Thread, // world.gpa
workers: std.AutoArrayHashMapUnmanaged(std.Thread.Id, Worker) = .empty, // world.gpa

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
is_running: bool = true,
pending_tasks: std.ArrayList(*Task) = .empty, // shared_gpa
completed_tasks: std.ArrayList(*Task) = .empty, // shared_gpa
tasks_left: usize = 0,
task_pool: std.heap.MemoryPool(Task), // world.gpa
phase_queue: std.DoublyLinkedList = .{}, // world.gpa
phase_queue_len: usize = 0,
phase_pool: std.heap.MemoryPool(Phase), // world.gpa

tasks_per_second: util.AmountPerSecond = .{},
chunks_to_mesh: std.AutoHashMapUnmanaged(Coords, void) = .empty, // world.gpa

cur_center: Coords = @splat(0),
cur_radius: Coords = @splat(0),

const ChunkManager = @This();
const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

pub const Options = struct {
    thread_count: ?usize = null,
};

pub fn init(world: *World, opts: Options) !*ChunkManager {
    errdefer |err| {
        logger.err("could not create chunk manager: {}", .{err});
    }

    const self = try world.get_gpa().create(ChunkManager);
    logger.info("{*}: initializing", .{self});
    const thread_count = opts.thread_count orelse try std.Thread.getCpuCount();

    self.* = .{
        .world = world,
        .main_tid = std.Thread.getCurrentId(),
        .phase_pool = .init(world.get_gpa()),
        .task_pool = .init(world.get_gpa()),
        .threads = try world.get_gpa().alloc(std.Thread, thread_count),
    };

    try self.workers.ensureTotalCapacity(world.get_gpa(), thread_count + 1);
    _ = Worker.init(self);

    for (self.threads) |*thread| {
        thread.* = try .spawn(.{}, Worker.init_and_run, .{self});
    }

    logger.info("{*}: initialized", .{self});

    return self;
}

pub fn deinit(self: *ChunkManager) void {
    logger.info("{*}: destroying", .{self});

    {
        self.mutex.lock();
        self.is_running = false;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    for (self.threads) |*thread| thread.join();
    for (self.workers.values()) |*worker| worker.deinit();
    self.workers.deinit(self.world.get_gpa());
    self.world.get_gpa().free(self.threads);

    self.pending_tasks.deinit(self.shared_gpa());
    self.completed_tasks.deinit(self.shared_gpa());
    self.task_pool.deinit();
    self.phase_pool.deinit();
    self.chunks_to_mesh.deinit(self.world.get_gpa());
    self.world.get_gpa().destroy(self);
}

pub fn schedule_load_region(self: *ChunkManager, center: Coords, radius: Coords) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.phase_queue.first != self.phase_queue.last) {
        const last_phase = Phase.from_link(self.phase_queue.last.?);
        if (last_phase.body == .loading) {
            last_phase.body.loading = .{ center, radius };
            return;
        }
    }

    const phase: *Phase = try self.phase_pool.create();
    phase.* = .{
        .body = .{ .loading = .{ center, radius } },
    };
    self.phase_queue.append(&phase.link);
    self.phase_queue_len += 1;
}

pub fn schedule_set_block(
    self: *ChunkManager,
    chunk: *Chunk,
    pos: World.Coords,
    block: Block,
) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (true) {
        const task1: *Task = try self.task_pool.create();
        task1.* = .{ .chunk = chunk, .body = .{ .set_block = .{ pos, block } } };
        try self.main_worker().run_task(task1);
        try self.completed_tasks.append(self.shared_gpa(), task1);

        for (Block.Neighbours(3).deltas) |d| {
            const next = chunk.get_chunk_block(d + pos) orelse continue;
            const next_chunk, _ = next;
            const task2: *Task = try self.task_pool.create();
            task2.* = .{ .chunk = next_chunk, .body = .meshing };
            try self.main_worker().run_task(task2);
            try self.completed_tasks.append(self.shared_gpa(), task2);
        }
        return;
    }

    const phase: *Phase = try self.phase_pool.create();
    phase.* = .{
        .body = .{ .set_block = .{
            pos + chunk.coords * @as(Coords, @splat(Chunk.CHUNK_SIZE)),
            block,
        } },
    };
    self.phase_queue.append(&phase.link);
    self.phase_queue_len += 1;
}

pub fn process(self: *ChunkManager) !void {
    self.mutex.lock();
    defer {
        self.mutex.unlock();
        self.cond.broadcast();
    }

    try self.process_phase();
    self.tasks_per_second.add(self.completed_tasks.items.len);

    for (self.completed_tasks.items) |task| {
        if (task.body == .meshing) {
            try self.world.renderer.upload_chunk_mesh(task.chunk);
        }
        self.task_pool.destroy(task);
    }
    self.completed_tasks.clearRetainingCapacity();
}

// on main thread in mutex
fn process_phase(self: *ChunkManager) !void {
    const cur_phase = if (self.phase_queue.first) |link|
        Phase.from_link(link)
    else if (self.chunks_to_mesh.count() != 0) blk: {
        const phase: *Phase = try self.phase_pool.create();
        phase.* = .{ .body = .meshing };
        self.phase_queue.prepend(&phase.link);
        self.phase_queue_len += 1;
        break :blk phase;
    } else return;

    switch (cur_phase.body) {
        .set_block => |x| {
            const world_pos, const block = x;
            const chunk_coords = World.world_to_chunk(world_pos);
            const block_coords = World.world_to_block(world_pos);

            const chunk = self.world.chunks.get(chunk_coords) orelse {
                logger.warn(
                    "{*}: attempted to set block at an inactive chunk {}",
                    .{ self, chunk_coords },
                );
                self.phase_queue_len -= 1;
                _ = self.phase_queue.popFirst();
                self.phase_pool.destroy(cur_phase);
                return try self.process_phase();
            };

            const task1: *Task = try self.task_pool.create();
            task1.* = .{ .chunk = chunk, .body = .{
                .set_block = .{ block_coords, block },
            } };
            try self.main_worker().run_task(task1);
            try self.completed_tasks.append(self.shared_gpa(), task1);
            for (Block.Neighbours(3).deltas) |d| {
                const world_coords = chunk.to_world_coords(d + block_coords);
                try self.chunks_to_mesh.put(
                    self.world.get_gpa(),
                    World.world_to_chunk(world_coords),
                    {},
                );
            }

            _ = self.phase_queue.popFirst();
            self.phase_pool.destroy(cur_phase);
            self.phase_queue_len -= 1;
        },

        .meshing => {
            if (!cur_phase.started) {
                std.debug.assert(self.pending_tasks.items.len == 0);
                std.debug.assert(self.tasks_left == 0);
                cur_phase.started = true;

                var it = self.chunks_to_mesh.keyIterator();
                while (it.next()) |coords| {
                    const chunk = self.world.chunks.get(coords.*) orelse continue;
                    const task: *Task = try self.task_pool.create();
                    task.* = .{ .chunk = chunk, .body = .meshing };
                    try self.pending_tasks.append(self.shared_gpa(), task);
                }
                self.chunks_to_mesh.clearRetainingCapacity();

                self.tasks_left = self.pending_tasks.items.len;
            }

            if (self.tasks_left == 0) {
                self.phase_queue_len -= 1;
                _ = self.phase_queue.popFirst();
                self.phase_pool.destroy(cur_phase);
            }
        },

        .loading => |body| {
            const center, const radius = body;
            if (@reduce(.And, center == self.cur_center) and
                @reduce(.And, radius == self.cur_radius))
            {
                self.phase_queue_len -= 1;
                _ = self.phase_queue.popFirst();
                self.phase_pool.destroy(cur_phase);
                return try self.process_phase();
            }

            if (!cur_phase.started) {
                std.debug.assert(self.pending_tasks.items.len == 0);
                std.debug.assert(self.tasks_left == 0);

                cur_phase.started = true;
                const cur_min = self.cur_center - self.cur_radius;
                const tgt_min = center - radius;
                const tgt_max = center + radius;

                {
                    const x_size: usize = @intCast(radius[0] * 2 + 1);
                    const y_size: usize = @intCast(radius[1] * 2 + 1);
                    const z_size: usize = @intCast(radius[2] * 2 + 1);

                    for (0..x_size) |x| {
                        for (0..y_size) |y| {
                            for (0..z_size) |z| {
                                const xyz: Coords = @intCast(@Vector(3, usize){ x, y, z });
                                const pos = xyz + tgt_min;

                                const entry = try self.world.chunks.getOrPut(
                                    self.world.get_gpa(),
                                    pos,
                                );
                                if (!entry.found_existing) {
                                    const chunk = try Chunk.init(self.world, pos);
                                    entry.value_ptr.* = chunk;

                                    const task: *Task = try self.task_pool.create();
                                    task.* = .{ .chunk = chunk, .body = .loading };
                                    try self.pending_tasks.append(
                                        self.shared_gpa(),
                                        task,
                                    );

                                    for (Block.Neighbours(3).deltas) |d| {
                                        try self.chunks_to_mesh.put(
                                            self.world.get_gpa(),
                                            d + pos,
                                            {},
                                        );
                                    }
                                }
                            }
                        }
                    }
                }

                {
                    const x_size: usize = @intCast(self.cur_radius[0] * 2 + 1);
                    const y_size: usize = @intCast(self.cur_radius[1] * 2 + 1);
                    const z_size: usize = @intCast(self.cur_radius[2] * 2 + 1);

                    for (0..x_size) |x| {
                        for (0..y_size) |y| {
                            for (0..z_size) |z| {
                                const xyz: Coords = @intCast(@Vector(3, usize){ x, y, z });
                                const pos = xyz + cur_min;
                                if (@reduce(.And, pos >= tgt_min) and
                                    @reduce(.And, pos <= tgt_max))
                                {
                                    continue;
                                }
                                try self.world.renderer.destroy_chunk_mesh(pos);

                                const kv = self.world.chunks.fetchSwapRemove(pos).?;
                                const chunk = kv.value;
                                chunk.deinit(self.shared_gpa());

                                for (Block.Neighbours(3).deltas) |d| {
                                    try self.chunks_to_mesh.put(
                                        self.world.get_gpa(),
                                        d + pos,
                                        {},
                                    );
                                }
                            }
                        }
                    }
                }

                self.tasks_left = self.pending_tasks.items.len;
            }

            if (self.tasks_left == 0) {
                self.phase_queue_len -= 1;
                _ = self.phase_queue.popFirst();
                self.phase_pool.destroy(cur_phase);
                self.cur_center = center;
                self.cur_radius = radius;
            }
        },
    }
}

const Phase = struct {
    link: std.DoublyLinkedList.Node = .{},
    body: Body,
    started: bool = false,

    const Body = union(enum) {
        loading: struct { Coords, Coords },
        meshing: void,
        set_block: struct { Coords, Block },
        const Tag = std.meta.Tag(Body);
    };

    fn from_link(link: *std.DoublyLinkedList.Node) *Phase {
        return @alignCast(@fieldParentPtr("link", link));
    }
};

const Task = struct {
    chunk: *Chunk,
    body: Body,
    const Body = union(enum) {
        loading: void,
        meshing: void,
        set_block: struct { Coords, Block },
        const Tag = std.meta.Tag(Body);
    };
};

pub const Worker = struct {
    parent: *ChunkManager,
    tid: std.Thread.Id,
    gpa: Gpa = .init,
    arena: std.heap.ArenaAllocator,

    pub fn temp(self: *Worker) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn shared(self: *Worker) std.mem.Allocator {
        return self.parent.shared_gpa();
    }

    pub fn is_main_thread(self: *Worker) bool {
        return self.tid == self.parent.main_tid;
    }

    fn init(parent: *ChunkManager) *Worker {
        parent.mutex.lock();
        defer parent.mutex.unlock();

        const tid = std.Thread.getCurrentId();
        const entry = parent.workers.getOrPutAssumeCapacity(tid);
        const self = entry.value_ptr;
        self.* = .{
            .parent = parent,
            .tid = tid,
            .gpa = .init,
            .arena = undefined,
        };
        self.arena = .init(self.gpa.allocator());

        logger.info("{*}: started", .{self});
        return self;
    }

    fn deinit(self: *Worker) void {
        logger.info("{*}: joined", .{self});

        self.arena.deinit();
        std.debug.assert(self.gpa.deinit() == .ok);
    }

    fn init_and_run(parent: *ChunkManager) void {
        const self = Worker.init(parent);

        self.run() catch |err| {
            logger.err("{*}: fatal error while running: {}", .{ self, err });
        };
    }

    fn run(self: *Worker) !void {
        self.parent.mutex.lock();
        defer self.parent.mutex.unlock();

        while (true) {
            while (self.parent.pending_tasks.pop()) |task| {
                if (!self.parent.is_running) break;

                self.parent.mutex.unlock();
                const ok = if (self.run_task(task)) |_|
                    true
                else |err| blk: {
                    logger.err(
                        "{*}: task {*}@{} failed: {}",
                        .{ self, task, task.chunk.coords, err },
                    );
                    break :blk false;
                };

                self.parent.mutex.lock();
                if (ok) {
                    logger.debug(
                        "{*}: finished task {*}@{}",
                        .{ self, task, task.chunk.coords },
                    );
                    try self.parent.completed_tasks.append(self.shared(), task);
                }
                self.parent.tasks_left -= 1;
            }

            if (self.parent.is_running) {
                self.parent.cond.wait(&self.parent.mutex);
            } else break;
        }
    }

    fn run_task(self: *Worker, task: *Task) !void {
        logger.debug(
            "{*}: picked up task {} {*}@{}",
            .{ self, @as(Task.Body.Tag, task.body), task, task.chunk.coords },
        );
        _ = self.arena.reset(.retain_capacity);
        switch (task.body) {
            .loading => try task.chunk.generate(self),
            .meshing => try task.chunk.build_mesh(self),
            .set_block => |x| try task.chunk.set_block_and_propagate_updates(x[0], x[1], self),
        }
    }
};

fn main_worker(self: *ChunkManager) *Worker {
    return self.workers.getPtr(self.main_tid).?;
}

pub fn on_frame_start(self: *ChunkManager) App.UnhandledError!void {
    try App.gui().add_to_frame(ChunkManager, "Debug", self, on_imgui, @src());
}

fn fmt_queue(queue: std.DoublyLinkedList, writer: *std.Io.Writer) !void {
    var cur = queue.first;
    try writer.print("[", .{});
    while (cur) |node| {
        const phase = Phase.from_link(node);
        try writer.print("{}, ", .{@as(Phase.Body.Tag, phase.body)});
        cur = node.next;
    }
    try writer.print("]", .{});
}

fn on_imgui(self: *ChunkManager) !void {
    const text1 = try std.fmt.allocPrintSentinel(App.frame_alloc(),
        \\Chunk Work:
        \\    queue:  {f}
        \\    work:   {d:.2}/s {d}:{d}
        \\    meshes: {d}
        \\    region: {d} {}...{}
        \\Chunk Memory:
        \\    shared: {f}
    , .{
        std.fmt.Alt(std.DoublyLinkedList, fmt_queue){ .data = self.phase_queue },
        self.tasks_per_second.measurement,
        self.tasks_left,
        self.completed_tasks.items.len,
        self.chunks_to_mesh.count(),
        self.world.chunks.count(),
        self.cur_center - self.cur_radius,
        self.cur_center + self.cur_radius,
        util.MemoryUsage.from_bytes(self.world.shared_gpa_base.total_requested_bytes),
    }, 0);

    c.igText("%s", @as(c_str, text1));

    for (self.workers.values()) |*worker| {
        const text2 = try std.fmt.allocPrintSentinel(App.frame_alloc(),
            \\    {*}: {f}
        , .{
            worker,
            util.MemoryUsage.from_bytes(worker.gpa.total_requested_bytes),
        }, 0);
        c.igText("%s", @as(c_str, text2));
    }
}

fn shared_gpa(self: *ChunkManager) std.mem.Allocator {
    return self.world.shared_gpa.allocator();
}
