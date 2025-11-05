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

pub fn request_set_block(self: *World, coords: WorldCoords, id: BlockId) !void {
    Log.log(.debug, "{*}: set_block at {}", .{ self, coords });
    const chunk_coords = world_to_chunk(coords);
    const block_coords = world_to_block(coords);
    const kv = self.active.fetchSwapRemove(chunk_coords) orelse {
        Log.log(.debug, "{*}: set_block at an invactive chunk {}", .{ self, chunk_coords });
        return;
    };
    const chunk = kv.value;
    chunk.set(block_coords, id);
    chunk.stage = .meshing;
    try self.worklist.put(App.gpa(), chunk.coords, chunk);
}

fn next_t(ray: zm.Rayf, cur_t: f32) struct { f32, BlockFace } {
    // ray: o + t * s
    // a + dt * s, dt s.t. one of a coords is an integer
    const a = ray.at(cur_t);
    const positive_faces: []const BlockFace = &.{ .right, .top, .front };
    const negative_faces: []const BlockFace = &.{ .left, .bot, .back };

    var dt = std.mem.zeroes([3]f32);
    const b = @floor(a) + @as(@Vector(3, f32), @splat(1)) - a;
    const c = @ceil(a) - @as(@Vector(3, f32), @splat(1)) - a;

    for (0..3) |i| {
        dt[i] = if (ray.direction[i] > 0)
            b[i] / ray.direction[i]
        else if (ray.direction[i] < 0)
            c[i] / ray.direction[i]
        else
            std.math.inf(f32);
    }

    var j: usize = 0;
    if (dt[1] < dt[j]) j = 1;
    if (dt[2] < dt[j]) j = 2;
    std.debug.assert(!std.math.isInf(dt[j]));
    std.debug.assert(dt[j] > 0);

    if (dt[j] < 0)
        return .{ cur_t + dt[j], negative_faces[j] }
    else
        return .{ cur_t + dt[j], positive_faces[j] };
}

fn to_world_coord(pos: zm.Vec3f) WorldCoords {
    return .init(@intFromFloat(pos[0]), @intFromFloat(pos[1]), @intFromFloat(pos[2]));
}

fn world_to_chunk(w: WorldCoords) ChunkCoords {
    return .init(@divFloor(w.x, CHUNK_SIZE), @divFloor(w.y, CHUNK_SIZE), @divFloor(w.z, CHUNK_SIZE));
}

fn world_to_block(w: WorldCoords) BlockCoords {
    return .init(
        @intCast(@mod(w.x, CHUNK_SIZE)),
        @intCast(@mod(w.y, CHUNK_SIZE)),
        @intCast(@mod(w.z, CHUNK_SIZE)),
    );
}

const RaycastResult = struct {
    t: f32,
    coords: WorldCoords,
    face: BlockFace,
    block: BlockId,
};
pub fn raycast(self: *World, ray: zm.Rayf, max_t: f32) ?RaycastResult {
    Log.log(.debug, "{*}: Raycast {}", .{ self, ray });

    var cur_t: f32 = 0;
    var cur_face: BlockFace = .top;

    while (cur_t <= max_t) {
        const coords = to_world_coord(ray.at(cur_t));
        const block = self.get_block(coords);
        Log.log(.debug, "{}:{}:{}:{?}", .{ cur_t, coords, cur_face, block });

        if (block != null and block.? != .air) {
            return RaycastResult{
                .t = cur_t,
                .coords = coords,
                .block = block.?,
                .face = cur_face,
            };
        }

        cur_t, cur_face = next_t(ray, cur_t);
    }
    return null;
}

fn get_block(self: *World, coords: WorldCoords) ?BlockId {
    const chunk = self.active.get(world_to_chunk(coords)) orelse return null;
    return chunk.get(world_to_block(coords));
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
pub const BlockFace = enum(u8) {
    front,
    back,
    right,
    left,
    top,
    bot,

    pub fn flip(self: BlockFace) BlockFace {
        return switch (self) {
            .front => .back,
            .back => .front,
            .right => .left,
            .left => .right,
            .top => .bot,
            .bot => .top,
        };
    }

    pub fn next_to(self: BlockFace, coords: WorldCoords) WorldCoords {
        return switch (self) {
            .front => WorldCoords.init(0, 0, 1).add(coords),
            .back => WorldCoords.init(0, 0, -1).add(coords),
            .right => WorldCoords.init(1, 0, 0).add(coords),
            .left => WorldCoords.init(-1, 0, 0).add(coords),
            .top => WorldCoords.init(0, 1, 0).add(coords),
            .bot => WorldCoords.init(0, -1, 0).add(coords),
        };
    }
};
pub const WorldCoords = util.Xyz(i32);
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
