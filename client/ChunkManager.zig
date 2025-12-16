const std = @import("std");
const App = @import("App.zig");
const Game = @import("Game.zig");
const Chunk = @import("Chunk.zig");
const c = @import("c.zig").c;
const MemoryUsage = @import("util.zig").MemoryUsage;

/// On the main thread, you may read from this at any time;
/// Worker threads read from here, while having the mutex, inside `pop_next_command`;
/// Worker threads may also write to individual chunk's `locked` field,
/// inside `pop_next_command -> cmd.prepare_to_run` (they have mutex at the time);
/// Writing (i.e. `put`/`remove`) happens on the main thread in `process -> cmd.apply`, and
/// the main thread has the mutex at that time;
///
/// If there are issues with writing inside workers, we can use an atomic for `locked`?
chunks: std.AutoHashMapUnmanaged(Chunk.Coords, *Chunk),

chunk_pool: std.heap.MemoryPool(Chunk),
command_pool: std.heap.MemoryPool(Command),

running: bool,
cmd_counter: u64,
// this provides the right to read/write to `worklist` and `complete`
mutex: std.Thread.Mutex,
condition: std.Thread.Condition,
threads: []std.Thread,
// use this inside threads, i.e. for `worklist` and `complete`
gpa: std.heap.DebugAllocator(.{ .enable_memory_limit = true }),
worklist: std.AutoArrayHashMapUnmanaged(Chunk.Coords, CommandQueue),
complete: std.ArrayList(*Command),

const ChunkManager = @This();
const Instance = struct {
    var instance: ChunkManager = undefined;
    var ok: bool = false;
};

fn instance() *ChunkManager {
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
        .complete = .empty,
        .running = true,
        .threads = try App.gpa().alloc(std.Thread, thread_cnt),
        .cmd_counter = 0,
        .gpa = .init,
    };
    const self = &Instance.instance;
    errdefer {
        for (self.threads) |t| t.join();
        App.gpa().free(self.threads);
    }

    for (self.threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{self});
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
        self.worklist.count(),
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

    try self.push_command(cmd);
    std.log.debug("{*}: cmd[{d}]:load({})", .{ self, cmd.idx, coords });
}

pub fn set_block(
    self: *ChunkManager,
    chunk_coords: Chunk.Coords,
    block_coords: Chunk.Coords,
    block_id: Chunk.BlockId,
) !void {
    const cmd: *Command = try self.command_pool.create();
    errdefer self.command_pool.destroy(cmd);
    cmd.* = .{
        .coords = chunk_coords,
        .body = .{ .set_block = .{ block_coords, block_id } },
        .link = .{},
        .idx = self.cmd_counter,
    };
    try self.push_command(cmd);
    std.log.debug(
        "{*}: cmd[{d}]:set_block({}@{}:{})",
        .{ self, cmd.idx, block_id, chunk_coords, block_coords },
    );
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
    try self.push_command(cmd);
    std.log.debug("{*}: cmd[{d}]:unload({})", .{ self, cmd.idx, coords });
}

fn push_command(self: *ChunkManager, cmd: *Command) !void {
    self.cmd_counter +%= 1;
    self.mutex.lock();
    defer self.mutex.unlock();
    const entry = try self.worklist.getOrPutValue(self.gpa.allocator(), cmd.coords, .{});
    const list = entry.value_ptr;
    list.prepend(&cmd.link);
    self.condition.signal();
}

pub fn process(self: *ChunkManager) !void {
    if (!self.mutex.tryLock()) return;
    defer self.mutex.unlock();

    var i: usize = 0;
    while (i < self.complete.items.len) {
        const cmd = self.complete.items[i];
        if (self.chunks.get(cmd.coords)) |old| {
            if (old.locked) {
                i += 1;
                continue;
            }
        }
        _ = self.complete.swapRemove(i);
        try cmd.apply();
        self.command_pool.destroy(cmd);
    }
}

// NOTE: runs in separate threads!
fn worker(self: *ChunkManager) void {
    self.mutex.lock();
    defer self.mutex.unlock(); // is locked inside the loop
    const tid = std.Thread.getCurrentId();
    std.log.info("[Thread {}] started", .{tid});

    while (true) {
        // at this point mutex is locked
        while (self.pop_next_command()) |cmd| {
            std.log.debug("[Thread {}] Picked up cmd[{d}]", .{ tid, cmd.idx });
            // relock here so that the other threads may get work
            // was locked at the start or on previous iter
            self.mutex.unlock();
            cmd.run();
            self.mutex.lock();

            self.complete.append(self.gpa.allocator(), cmd) catch |err| {
                std.log.err(
                    "[Thread {}] could not mark the command as completed! {}. Badness likely ensues",
                    .{ tid, err },
                );
            };
        }

        if (self.running) {
            self.condition.wait(&self.mutex);
        } else break;
    }

    std.log.info("[Thread {}] joined", .{tid});
}

// NOTE: runs in separate threads, but by the thread that has the mutex
fn pop_next_command(self: *ChunkManager) ?*Command {
    for (self.worklist.values()) |*list| {
        const link: *std.DoublyLinkedList.Node = list.first.?;
        const cmd: *Command = @alignCast(@fieldParentPtr("link", link));
        if (self.chunks.get(cmd.coords)) |cur| {
            if (cur.locked) continue;
        }
        if (!cmd.prepare_to_run()) continue;

        list.remove(link);
        if (list.first == null) {
            _ = self.worklist.swapRemove(cmd.coords);
        }
        return cmd;
    }
    return null;
}

const CommandQueue = std.DoublyLinkedList;

const Command = struct {
    coords: Chunk.Coords,
    body: Body,
    link: std.DoublyLinkedList.Node,
    idx: u64,

    // NOTE: runs in separate threads, but by the thread that has the mutex
    pub fn prepare_to_run(self: *Command) bool {
        if (instance().chunks.get(self.coords)) |old| {
            old.locked = true;
        }

        return true;
    }

    // NOTE: runs in separate threads!
    pub fn run(self: *Command) void {
        switch (self.body) {
            .load => |ch| ch.generate(),
            .unload => {},
            .set_block => {},
            // TODO
            .mesh => |_| {},
        }
    }

    pub fn apply(self: *Command) !void {
        switch (self.body) {
            .load => |ch| {
                if (try instance().chunks.fetchPut(App.gpa(), ch.coords, ch)) |old| {
                    std.debug.assert(!old.value.locked);
                    instance().chunk_pool.destroy(old.value);
                }
                ch.locked = false;
                std.log.debug("{*}: cmd[{d}]: loaded {}", .{ instance(), self.idx, ch.coords });
            },
            .set_block => |b| {
                const chunk = instance().chunks.get(self.coords) orelse {
                    std.log.warn(
                        "{*}: cmd[{d}]: tried to set_block on inactive chunk",
                        .{ instance(), self.idx },
                    );
                    return;
                };
                chunk.set(b[0], b[1]);
                chunk.locked = false;
                std.log.debug(
                    "{*}: cmd[{d}]: set block {}@{}:{}",
                    .{ instance(), self.idx, b[1], self.coords, b[0] },
                );
            },
            .unload => {
                const chunk = instance().chunks.fetchRemove(self.coords) orelse {
                    std.log.warn("{*}: cmd[{d}]: tried to unload an inactive chunk", .{ instance(), self.idx });
                    return;
                };
                instance().chunk_pool.destroy(chunk.value);
                std.log.debug("{*} cmd[{d}]: unloaded {}", .{ instance(), self.idx, self.coords });
            },
            // TODO
            .mesh => {},
        }
    }

    const Body = union(enum) {
        load: *Chunk,
        unload: void,
        set_block: struct { Chunk.Coords, Chunk.BlockId },
        mesh: *Chunk,
    };
};
