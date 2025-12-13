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
    return @intFromFloat(@floor(pos));
}

pub fn world_to_chunk(w: WorldCoords) ChunkCoords {
    return @divFloor(w, @as(WorldCoords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: WorldCoords) BlockCoords {
    return @mod(w, @as(WorldCoords, @splat(CHUNK_SIZE)));
}

pub fn world_coords(chunk: ChunkCoords, block: BlockCoords) WorldCoords {
    return chunk + block * @as(BlockCoords, @splat(CHUNK_SIZE));
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

    var iter_cnt: usize = 0;
    while (cur_t <= max_t) : (iter_cnt += 1) {
        if (iter_cnt >= 100) {
            Log.log(.warn, "The raycasting bug: {}", .{ray});
            Log.log(.warn, "Goodbye!", .{});
            std.debug.assert(false);
        }

        const cur_pos = r.at(cur_t);

        const dx = @select(f32, @ceil(cur_pos) == cur_pos, one, @ceil(cur_pos) - cur_pos);
        const dt = dx / r.direction;

        const eps = 1e-4;
        var min_dim: ?usize = null;
        for (0..3) |i| {
            if ((min_dim == null or dt[min_dim.?] > dt[i]) and @abs(dt[i]) > eps) min_dim = i;
        }
        const j = if (min_dim) |m| m else return null;

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

pub fn get_block(self: *World, coords: WorldCoords) ?BlockId {
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
pub const BlockFace = enum(u3) {
    front,
    back,
    right,
    left,
    top,
    bot,

    pub const list: []const BlockFace = @ptrCast(std.meta.tags(@This()));

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

    pub fn front_dir(self: BlockFace) WorldCoords {
        return switch (self) {
            .front => .{ 0, 0, 1 },
            .back => .{ 0, 0, -1 },
            .right => .{ 1, 0, 0 },
            .left => .{ -1, 0, 0 },
            .top => .{ 0, 1, 0 },
            .bot => .{ 0, -1, 0 },
        };
    }

    pub fn left_dir(self: BlockFace) WorldCoords {
        return switch (self) {
            .front => .{ -1, 0, 0 },
            .back => .{ 1, 0, 0 },
            .right => .{ 0, 0, 1 },
            .left => .{ 0, 0, -1 },
            .top => .{ -1, 0, 0 },
            .bot => .{ 1, 0, 0 },
        };
    }

    pub fn up_dir(self: BlockFace) WorldCoords {
        return switch (self) {
            .front => .{ 0, 1, 0 },
            .back => .{ 0, 1, 0 },
            .right => .{ 0, 1, 0 },
            .left => .{ 0, 1, 0 },
            .top => .{ 0, 0, 1 },
            .bot => .{ 0, 0, 1 },
        };
    }
};

pub const WorldCoords = @Vector(3, i32);
pub const ChunkCoords = @Vector(3, i32);
pub const BlockCoords = @Vector(3, i32);

fn init_chunks(self: *World) !void {
    for (0..World.DIM) |i| {
        for (0..World.DIM) |j| {
            for (0..World.HEIGHT) |k| {
                const x = @as(i32, @intCast(i)) - DIM / 2;
                const y = @as(i32, @intCast(k)) - HEIGHT + 1;
                const z = @as(i32, @intCast(j)) - DIM / 2;
                try self.request_load_chunk(.{ x, y, z });
            }
        }
    }
}
