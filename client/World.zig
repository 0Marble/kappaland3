const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const std = @import("std");
const zm = @import("zm");
const util = @import("util.zig");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const Chunk = @import("Chunk.zig");
const c = @import("c.zig").c;

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
    const chunk_coords = world_to_chunk(coords);
    const block_coords = world_to_block(coords);
    const kv = self.active.fetchSwapRemove(chunk_coords) orelse {
        Log.log(.warn, "{*}: set_block at an invactive chunk {}", .{ self, chunk_coords });
        return;
    };
    const chunk = kv.value;
    chunk.set(block_coords, id);
    chunk.stage = .meshing;
    try self.worklist.put(App.gpa(), chunk.coords, chunk);
}

pub fn on_frame_start(self: *World) !void {
    try App.gui().add_to_frame(World, "Debug", self, struct {
        fn callback(this: *World) !void {
            c.igText("Chunks Active: %zu", this.active.count());
            c.igText("Chunks in Worklist: %zu", this.worklist.count());
        }
    }.callback, @src());
}

fn to_world_coord(pos: zm.Vec3f) WorldCoords {
    return .init(@intFromFloat(@floor(pos[0])), @intFromFloat(@floor(pos[1])), @intFromFloat(@floor(pos[2])));
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
    hit_coords: WorldCoords,
    prev_coords: WorldCoords,
    block: BlockId,
};
pub fn raycast(self: *World, ray: zm.Rayf, max_t: f32) ?RaycastResult {
    const one: zm.Vec3f = @splat(1);

    var cur_t: f32 = 0;
    var r = ray;
    var mul = one;
    for (0..3) |i| {
        if (r.direction[i] < 0) {
            r.direction[i] *= -1;
            r.origin[i] *= -1;
            mul[i] = -1;
        }
    }
    var prev_block = to_world_coord(ray.origin);

    while (cur_t <= max_t) {
        const cur_pos = r.at(cur_t);

        const dx = @select(f32, @ceil(cur_pos) == cur_pos, one, @ceil(cur_pos) - cur_pos);
        const dt = dx / r.direction;

        var j: usize = 0;
        if (dt[j] > dt[1]) j = 1;
        if (dt[j] > dt[2]) j = 2;

        const cur_block = to_world_coord(r.at(cur_t + 0.5 * dt[j]) * mul);
        const block = self.get_block(cur_block);
        if (block != null and block.? != .air) {
            return RaycastResult{
                .t = cur_t,
                .block = block.?,
                .hit_coords = cur_block,
                .prev_coords = prev_block,
            };
        }

        cur_t += dt[j];
        prev_block = cur_block;
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
