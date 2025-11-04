const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const std = @import("std");
const zm = @import("zm");
const util = @import("util.zig");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const Chunk = @import("Chunk.zig");

pub const CHUNK_SIZE = 16;
pub const DIM: comptime_int = Options.world_size;
pub const HEIGHT: comptime_int = Options.world_height;
const CHUNKS_PROCESSED_PER_FRAME = 10;

worklist: std.AutoArrayHashMapUnmanaged(ChunkCoords, *Chunk),
active: std.AutoArrayHashMapUnmanaged(ChunkCoords, *Chunk),
freelist: std.ArrayListUnmanaged(*Chunk),

const World = @This();
pub fn init(self: *World) !void {
    self.worklist = .empty;
    self.active = .empty;
    self.freelist = .empty;

    try self.init_chunks();
}

pub fn deinit(self: *World) void {
    for (self.worklist.values()) |chunk| chunk.deinit();
    for (self.active.values()) |chunk| chunk.deinit();
    for (self.freelist.items) |chunk| chunk.deinit();

    self.worklist.deinit(App.gpa());
    self.active.deinit(App.gpa());
    self.freelist.deinit(App.gpa());
}

pub fn request_load_chunk(self: *World, coords: ChunkCoords) !void {
    if (self.active.get(coords)) |_| return;
    if (self.worklist.get(coords)) |_| return;

    const chunk = if (self.freelist.pop()) |old|
        old
    else
        try Chunk.create();
    chunk.init(coords);
    try self.worklist.put(App.gpa(), coords, chunk);
}

pub fn request_set_block(self: *World, chunk: ChunkCoords, block: BlockCoords, id: BlockId) !void {
    _ = self; // autofix
    _ = chunk; // autofix
    _ = block; // autofix
    _ = id; // autofix
    Log.log(.warn, "TODO: block placing", .{});
}

pub fn process_work(self: *World) !void {
    for (0..CHUNKS_PROCESSED_PER_FRAME) |_| {
        const kv = self.worklist.pop() orelse break;
        const chunk = kv.value;
        try chunk.process();
        if (chunk.stage != .active) {
            try self.worklist.put(App.gpa(), chunk.coords, chunk);
        } else {
            if (try self.active.fetchPut(App.gpa(), chunk.coords, chunk)) |_| {
                Log.log(.warn, "{*}: Duplicate chunks at coordinate {}", .{ self, chunk.coords });
            }
        }
    }
}

pub const BlockId = enum(u16) { air = 0, stone = 1, dirt = 2, grass = 3, _ };
pub const BlockFace = enum(u8) { front, back, right, left, top, bot };
pub const ChunkCoords = util.Xyz(i32);
pub const BlockCoords = util.Xyz(usize);

fn init_chunks(self: *World) !void {
    for (0..World.DIM) |i| {
        for (0..World.DIM) |j| {
            for (0..World.HEIGHT) |k| {
                const x = @as(i32, @intCast(i)) - DIM / 2;
                const y = @as(i32, @intCast(k)) - HEIGHT + 1;
                const z = @as(i32, @intCast(j)) - DIM / 2;
                try self.request_load_chunk(.{ .x = x, .y = y, .z = z });
            }
        }
    }
}
