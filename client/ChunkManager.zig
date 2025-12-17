const std = @import("std");
const App = @import("App.zig");
const Game = @import("Game.zig");
const Chunk = @import("Chunk.zig");
const c = @import("c.zig").c;
const MemoryUsage = @import("util.zig").MemoryUsage;
const Block = @import("Block.zig");

const logger = std.log.scoped(.chunk_manager);

chunks: std.AutoArrayHashMapUnmanaged(Chunk.Coords, *Chunk),

chunk_pool: std.heap.MemoryPool(Chunk),
command_pool: std.heap.MemoryPool(Command),

running: bool,
cmd_counter: u64,
// this provides the right to read/write to `worklist` and `complete`
mutex: std.Thread.Mutex,
condition: std.Thread.Condition,
threads: []std.Thread,
// use this inside threads, i.e. for `worklist` and `complete`
gpa: Gpa,
worklist: std.AutoArrayHashMapUnmanaged(Chunk.Coords, Work),
worklist_size: usize,
complete: std.ArrayList(*Command),
thread_gpas: []Gpa,

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

const ChunkManager = @This();
const Instance = struct {
    var instance: ChunkManager = undefined;
    var ok: bool = false;
};

pub fn instance() *ChunkManager {
    return &Instance.instance;
}

pub fn init(thread_count: ?usize) !*ChunkManager {
    if (Instance.ok) return &Instance.instance;
    const thread_cnt = thread_count orelse try std.Thread.getCpuCount();

    Instance.instance = .{
        .chunk_pool = .init(App.gpa()),
        .command_pool = .init(App.gpa()),
        .chunks = .empty,
        .mutex = .{},
        .condition = .{},
        .worklist = .empty,
        .worklist_size = 0,
        .complete = .empty,
        .running = true,
        .threads = try App.gpa().alloc(std.Thread, thread_cnt),
        .thread_gpas = try App.gpa().alloc(Gpa, thread_cnt),
        .cmd_counter = 0,
        .gpa = .init,
    };
    const self = &Instance.instance;
    errdefer {
        for (self.threads) |t| t.join();
        App.gpa().free(self.thread_gpas);
        App.gpa().free(self.threads);
    }

    for (self.threads, self.thread_gpas) |*t, *g| {
        g.* = .init;
        t.* = try std.Thread.spawn(.{}, worker, .{ self, g.allocator() });
    }

    Instance.ok = true;
    return self;
}

pub fn on_imgui(self: *ChunkManager) !void {
    // race but its non-critical
    const str = try std.fmt.allocPrintSentinel(App.frame_alloc(),
        \\Chunks:
        \\    active:   {d}
        \\    worklist: {d}
        \\    complete: {d}
        \\    thread_gpa: {f}
    , .{
        self.chunks.count(),
        self.worklist_size,
        self.complete.items.len,
        MemoryUsage.from_bytes(self.gpa.total_requested_bytes),
    }, 0);
    c.igText("%s", str.ptr);
}

pub fn deinit(self: *ChunkManager) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.running = false;
    }
    self.condition.broadcast();
    for (self.threads) |t| t.join();
    App.gpa().free(self.threads);

    for (self.thread_gpas) |*g| _ = g.deinit();
    App.gpa().free(self.thread_gpas);

    for (self.chunks.values()) |chunk| {
        if (chunk.faces) |faces| self.gpa.allocator().free(faces);
    }
    for (self.complete.items) |cmd| {
        switch (cmd.body) {
            .mesh => |mesh| if (mesh[1]) |faces| self.gpa.allocator().free(faces),
            else => {},
        }
    }

    self.chunks.deinit(App.gpa());
    self.chunk_pool.deinit();
    self.command_pool.deinit();
    self.worklist.deinit(self.gpa.allocator());
    self.complete.deinit(self.gpa.allocator());
    _ = self.gpa.deinit();
    Instance.ok = false;
}

pub fn load(self: *ChunkManager, coords: Chunk.Coords) !void {
    const cmd: *Command = try self.command_pool.create();
    errdefer self.command_pool.destroy(cmd);
    const chunk: *Chunk = try self.chunk_pool.create();
    errdefer self.chunk_pool.destroy(chunk);
    chunk.init(coords);

    cmd.* = .{
        .coords = coords,
        .body = .{ .load = chunk },
        .link = .{},
        .idx = self.cmd_counter,
    };

    logger.debug("{*}: cmd[{d}]:load({})", .{ self, cmd.idx, coords });

    self.mutex.lock();
    defer self.mutex.unlock();
    if (try self.push_command(cmd)) try self.build_mesh(coords);
}

// already has the mutex, since its not called directly
fn build_mesh(self: *ChunkManager, coords: Chunk.Coords) !void {
    const cmd: *Command = try self.command_pool.create();
    errdefer self.command_pool.destroy(cmd);
    cmd.* = .{
        .coords = coords,
        .body = .{ .mesh = .{ null, null } },
        .link = .{},
        .idx = self.cmd_counter,
    };
    logger.debug("{*}: cmd[{d}]:build_mesh({})", .{ self, cmd.idx, coords });

    _ = try self.push_command(cmd);
}

pub fn set_block(
    self: *ChunkManager,
    chunk_coords: Chunk.Coords,
    block_coords: Chunk.Coords,
    block_id: Block.Id,
) !void {
    const cmd: *Command = try self.command_pool.create();
    errdefer self.command_pool.destroy(cmd);
    cmd.* = .{
        .coords = chunk_coords,
        .body = .{ .set_block = .{ block_coords, block_id } },
        .link = .{},
        .idx = self.cmd_counter,
    };
    logger.debug(
        "{*}: cmd[{d}]:set_block({}@{}:{})",
        .{ self, cmd.idx, block_id, chunk_coords, block_coords },
    );

    self.mutex.lock();
    defer self.mutex.unlock();
    if (try self.push_command(cmd)) try self.build_mesh(chunk_coords);
}

pub fn unload(self: *ChunkManager, coords: Chunk.Coords) !void {
    const cmd: *Command = try self.command_pool.create();
    errdefer self.command_pool.destroy(cmd);
    cmd.* = .{
        .coords = coords,
        .body = .{ .unload = {} },
        .link = .{},
        .idx = self.cmd_counter,
    };

    logger.debug("{*}: cmd[{d}]:unload({})", .{ self, cmd.idx, coords });

    self.mutex.lock();
    defer self.mutex.unlock();
    _ = try self.push_command(cmd);
}

// we have the mutex here
fn push_command(self: *ChunkManager, cmd: *Command) !bool {
    self.cmd_counter +%= 1;
    const entry = try self.worklist.getOrPutValue(self.gpa.allocator(), cmd.coords, .{});

    const list = &entry.value_ptr.commands;
    var it = list.first;
    while (it) |link| : (it = link.next) {
        const other: *Command = @alignCast(@fieldParentPtr("link", link));
        if (other.body == .load and cmd.body == .load) {
            self.command_pool.destroy(cmd);
            return false;
        }
    }

    self.worklist_size += 1;
    list.prepend(&cmd.link);
    self.condition.signal();
    return true;
}

pub fn process(self: *ChunkManager) !void {
    if (!self.mutex.tryLock()) return;
    defer {
        self.mutex.unlock();
        self.condition.broadcast();
    }

    for (self.complete.items) |cmd| {
        try cmd.apply();
    }
    self.complete.clearRetainingCapacity();
}

// NOTE: runs in separate threads!
fn worker(self: *ChunkManager, gpa: std.mem.Allocator) void {
    self.mutex.lock();
    defer self.mutex.unlock(); // is locked inside the loop

    const tid = std.Thread.getCurrentId();
    logger.info("[Thread {}] started", .{tid});

    var faces = std.array_list.Managed(Chunk.Face).init(gpa);
    defer faces.deinit();

    while (true) {
        // at this point mutex is locked
        while (self.pop_next_command()) |cmd| {
            logger.debug(
                "[Thread {}] Picked up cmd[{d}]: {}",
                .{ tid, cmd.idx, std.meta.activeTag(cmd.body) },
            );
            // relock here so that the other threads may get work
            // was locked at the start or on previous iter
            self.mutex.unlock();

            faces.clearRetainingCapacity();
            cmd.run(&faces) catch |err| {
                logger.warn("{*}: cmd[{d}]: failed: {}", .{ self, cmd.idx, err });
                cmd.body = .noop;
            };

            logger.debug("[Thread {}] Completed cmd[{d}]", .{ tid, cmd.idx });
            self.mutex.lock();

            switch (cmd.body) {
                .mesh => |*mesh| {
                    std.debug.assert(mesh[0] != null);
                    mesh[1] = self.gpa.allocator().dupe(Chunk.Face, faces.items) catch |err| blk: {
                        logger.err(
                            "{*}: cmd[{d}]: could not dupe chunk faces: {}",
                            .{ self, cmd.idx, err },
                        );
                        break :blk null;
                    };
                },
                else => {},
            }

            self.complete.append(self.gpa.allocator(), cmd) catch |err| {
                logger.err(
                    "[Thread {}] cmd[{d}]: could not mark the command as completed! {}",
                    .{ tid, cmd.idx, err },
                );
            };
        }

        if (self.running) {
            self.condition.wait(&self.mutex);
        } else break;
    }

    logger.info("[Thread {}] joined", .{tid});
}

// NOTE: runs in separate threads, but by the thread that has the mutex
fn pop_next_command(self: *ChunkManager) ?*Command {
    for (self.worklist.values()) |*work| {
        if (work.lock != .open) continue;
        const link = work.commands.last orelse continue;
        const cmd: *Command = @alignCast(@fieldParentPtr("link", link));
        if (!cmd.prepare_to_run()) continue;
        work.commands.remove(link);
        work.lock = .write;
        self.worklist_size -= 1;
        return cmd;
    }
    return null;
}

const Command = struct {
    coords: Chunk.Coords,
    body: Body,
    link: std.DoublyLinkedList.Node,
    idx: u64,

    // NOTE: runs in separate threads, but by the thread that has the mutex
    pub fn prepare_to_run(self: *Command) bool {
        switch (self.body) {
            .mesh => |*mesh| {
                std.debug.assert(mesh[0] == null);
                const chunk = instance().chunks.get(self.coords) orelse {
                    logger.warn(
                        "{*}: cmd[{d}]: requested meshing for inactive chunk {}, converting to noop",
                        .{ instance(), self.idx, self.coords },
                    );
                    self.body = .noop;
                    return true;
                };

                for (Chunk.neighbours2) |d| {
                    const neighbour_work = instance().worklist.getPtr(d + self.coords) orelse {
                        logger.warn(
                            "{*}: cmd[{d}]: no data for neighbour of {}, skipping",
                            .{ instance(), self.idx, self.coords },
                        );
                        self.body = .noop;
                        return true;
                    };
                    if (neighbour_work.lock == .write) return false;
                }

                for (Chunk.neighbours2) |d| {
                    instance().worklist.getPtr(d + self.coords).?.lock.rd_lock();
                }

                mesh.* = .{ chunk, null };
                chunk.ensure_neighbours();
            },
            else => {},
        }
        return true;
    }

    // NOTE: runs in separate threads!
    pub fn run(self: *Command, faces: *std.array_list.Managed(Chunk.Face)) !void {
        switch (self.body) {
            .load => |ch| ch.generate(),
            .unload => {},
            .set_block => {},
            .mesh => |mesh| {
                try mesh[0].?.build_mesh(faces);
            },
            .noop => {},
        }
    }

    // runs inside main thread while it has the mutex
    pub fn apply(self: *Command) !void {
        switch (self.body) {
            .load => |ch| {
                const lock = &instance().worklist.getPtr(self.coords).?.lock;
                std.debug.assert(lock.* == .write);

                if (try instance().chunks.fetchPut(App.gpa(), ch.coords, ch)) |old| {
                    instance().chunk_pool.destroy(old.value);
                }

                lock.* = .open;
                logger.debug("{*}: cmd[{d}]: loaded {}", .{ instance(), self.idx, ch.coords });

                ch.ensure_neighbours();
                for (ch.neighbours2_cache) |n| {
                    const chunk = n orelse continue;
                    chunk.cache_valid = false;
                }
            },
            .set_block => |b| {
                const chunk = instance().chunks.get(self.coords) orelse {
                    logger.warn(
                        "{*}: cmd[{d}]: tried to set_block on inactive chunk",
                        .{ instance(), self.idx },
                    );
                    return;
                };

                const lock = &instance().worklist.getPtr(self.coords).?.lock;
                std.debug.assert(lock.* == .write);
                lock.* = .open;

                chunk.set(b[0], b[1]);

                logger.debug(
                    "{*}: cmd[{d}]: set block {}@{}:{}",
                    .{ instance(), self.idx, b[1], self.coords, b[0] },
                );

                chunk.ensure_neighbours();
                for (chunk.neighbours2_cache) |n| {
                    const other = n orelse continue;
                    try instance().build_mesh(other.coords);
                }
            },
            .unload => {
                const kv = instance().chunks.fetchSwapRemove(self.coords) orelse {
                    logger.warn(
                        "{*}: cmd[{d}]: tried to unload an inactive chunk {}",
                        .{ instance(), self.idx, self.coords },
                    );
                    return;
                };
                logger.debug("{*} cmd[{d}]: unloaded {}", .{ instance(), self.idx, self.coords });
                const lock = &instance().worklist.getPtr(self.coords).?.lock;
                std.debug.assert(lock.* == .write);
                lock.* = .open;

                const chunk = kv.value;
                if (chunk.faces != null) try Game.instance().renderer.destroy_chunk_mesh(chunk);

                chunk.ensure_neighbours();
                for (chunk.neighbours2_cache) |n| {
                    const ch = n orelse continue;
                    ch.cache_valid = false;
                }
                instance().chunk_pool.destroy(chunk);
            },
            .mesh => |mesh| {
                std.debug.assert(@reduce(.And, mesh[0].?.coords == self.coords));
                const lock = &instance().worklist.getPtr(self.coords).?.lock;
                std.debug.assert(lock.* == .write);
                lock.* = .open;

                mesh[0].?.faces = mesh[1];
                if (mesh[1]) |faces| {
                    logger.debug(
                        "{*} cmd[{d}]: uploaded mesh for {}, size={d}",
                        .{ instance(), self.idx, self.coords, faces.len * @sizeOf(Chunk.Face) },
                    );
                    try Game.instance().renderer.upload_chunk_mesh(mesh[0].?);
                } else {
                    logger.warn(
                        "{*} cmd[{d}]: failed to build mesh for {}",
                        .{ instance(), self.idx, self.coords },
                    );
                }

                for (Chunk.neighbours2) |d| {
                    const l = &instance().worklist.getPtr(self.coords + d).?.lock;
                    std.debug.assert(l.* == .read);
                    l.rd_unlock();
                }
            },
            .noop => {
                const lock = &instance().worklist.getPtr(self.coords).?.lock;
                std.debug.assert(lock.* == .write);
                lock.* = .open;
            },
        }
    }

    const Body = union(enum) {
        load: *Chunk,
        unload: void,
        set_block: struct { Chunk.Coords, Block.Id },
        mesh: struct { ?*Chunk, ?[]const Chunk.Face },
        noop: void,
    };
};

const Work = struct {
    lock: Lock = .open,
    commands: std.DoublyLinkedList = .{},

    const Lock = union(enum) {
        open,
        read: usize,
        write,

        fn rd_lock(self: *Lock) void {
            switch (self.*) {
                .open => self.* = .{ .read = 1 },
                .read => |*x| x.* += 1,
                .write => unreachable,
            }
        }

        fn rd_unlock(self: *Lock) void {
            switch (self.*) {
                .read => |*x| {
                    x.* -= 1;
                    if (x.* == 0) self.* = .open;
                },
                else => unreachable,
            }
        }
    };
};
