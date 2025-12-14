const World = @import("World.zig");
const std = @import("std");
const App = @import("App.zig");
const zm = @import("zm");
const Options = @import("ClientOptions");

const CHUNK_SIZE = World.CHUNK_SIZE;
pub const X_OFFSET = 1;
pub const Z_OFFSET = CHUNK_SIZE;
pub const Y_OFFSET = CHUNK_SIZE * CHUNK_SIZE;

coords: World.ChunkCoords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]World.BlockId,

const Chunk = @This();

pub fn init(coords: World.ChunkCoords) !*Chunk {
    const self = try App.static_alloc().create(Chunk);
    self.coords = coords;
    return self;
}

pub fn get(self: *Chunk, pos: World.BlockCoords) World.BlockId {
    const i = @reduce(.Add, pos * World.BlockCoords{ X_OFFSET, Y_OFFSET, Z_OFFSET });
    return self.blocks[@intCast(i)];
}

pub fn is_solid(self: *Chunk, pos: World.BlockCoords) bool {
    const b = self.get_safe(pos);
    if (b == null or b == .air) return false;
    return true;
}

pub fn get_safe(self: *Chunk, pos: World.BlockCoords) ?World.BlockId {
    const size = World.BlockCoords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE };
    const stride = World.BlockCoords{ X_OFFSET, Y_OFFSET, Z_OFFSET };
    const zero = zm.vec.zero(3, i32);
    const a = pos < size;
    const b = pos >= zero;
    if (!@reduce(.And, a) or !@reduce(.And, b)) {
        return null;
    }

    const i = @reduce(.Add, pos * stride);
    return self.blocks[@intCast(i)];
}

pub fn set(self: *Chunk, pos: World.BlockCoords, block: World.BlockId) void {
    const i = @reduce(.Add, pos * World.BlockCoords{ X_OFFSET, Y_OFFSET, Z_OFFSET });
    self.blocks[@intCast(i)] = block;
}

pub fn generate(self: *Chunk) void {
    const fptr = @field(Chunk, "generate_" ++ Options.world_gen);
    @call(.auto, fptr, .{self});
}

fn generate_solid(self: *Chunk) void {
    @memset(&self.blocks, .stone);
}

fn generate_flat(self: *Chunk) void {
    @memset(&self.blocks, .air);
    if (self.coords[1] > 0) return;
    if (self.coords[1] < 0) {
        @memset(&self.blocks, .stone);
        return;
    }

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                const pos: World.BlockCoords = @intCast(@Vector(3, usize){ x, y, z });
                switch (y) {
                    0...4 => self.set(pos, .stone),
                    5...7 => self.set(pos, .dirt),
                    8 => self.set(pos, .grass),
                    else => self.set(pos, .air),
                }
            }
        }
    }
}

fn generate_balls(self: *Chunk) void {
    const scale: zm.Vec3f = @splat(std.math.pi / 8.0);
    const size: World.BlockCoords = @splat(CHUNK_SIZE);

    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            for (0..CHUNK_SIZE) |k| {
                const pos = World.BlockCoords{
                    @intCast(i),
                    @intCast(j),
                    @intCast(k),
                } + self.coords * size;
                const xyz = @as(zm.Vec3f, @floatFromInt(pos)) * scale;

                const idx = i * X_OFFSET + j * Y_OFFSET + k * Z_OFFSET;
                const w = @abs(@sin(xyz[0]) + @cos(xyz[2]) + @sin(xyz[1]));

                if (w < 3 * 0.4) {
                    self.blocks[idx] = .air;
                } else {
                    self.blocks[idx] = .stone;
                }
            }
        }
    }
}

fn generate_wavy(self: *Chunk) void {
    const scale = std.math.pi / 16.0;
    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |k| {
            const x: f32 = @floatFromInt(self.coords[0] * CHUNK_SIZE + @as(i32, @intCast(i)));
            const z: f32 = @floatFromInt(self.coords[2] * CHUNK_SIZE + @as(i32, @intCast(k)));
            const top: f32 = (@sin(x * scale) + @cos(z * scale)) * 4.0 + 8.0;

            for (0..CHUNK_SIZE) |j| {
                const pos = World.BlockCoords{
                    @intCast(i),
                    @intCast(j),
                    @intCast(k),
                };
                const y: f32 = @floatFromInt(self.coords[1] *
                    CHUNK_SIZE +
                    @as(i32, @intCast(j)));

                if (y < top) {
                    self.set(pos, .stone);
                } else {
                    self.set(pos, .air);
                }
            }
        }
    }
}

pub fn aabb(self: *Chunk) zm.AABBf {
    const size = @as(zm.Vec3f, @splat(CHUNK_SIZE));
    const pos = @as(zm.Vec3f, @floatFromInt(self.coords.as_vec())) * size;
    return .init(pos, pos + size);
}

pub fn get_occluder(self: *Chunk) ?zm.AABBf {
    const all_full = std.mem.indexOfScalar(World.BlockId, &self.blocks, .air) == null;
    if (!all_full) return null;
    return self.aabb();
}

pub fn bounding_sphere(self: *Chunk) zm.Vec4f {
    const size: zm.Vec3f = @splat(CHUNK_SIZE);
    const coords: zm.Vec3f = @floatFromInt(self.coords);
    const pos = coords * size + size * @as(zm.Vec3f, @splat(0.5));
    const rad: f32 = @as(f32, @floatFromInt(CHUNK_SIZE)) * @sqrt(3.0) / 2.0;

    return .{ pos[0], pos[1], pos[2], rad };
}

pub const neighbours: [6]World.ChunkCoords = .{
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
    .{ 1, 0, 0 },
    .{ -1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
};
