const std = @import("std");
const App = @import("App.zig");
const zm = @import("zm");
const Options = @import("Build").Options;
const Handle = @import("GpuAlloc.zig").Handle;
const Block = @import("Block.zig");
const ChunkManager = @import("ChunkManager.zig");

pub const CHUNK_SIZE = 16;
pub const X_OFFSET = 1;
pub const Z_OFFSET = CHUNK_SIZE;
pub const Y_OFFSET = CHUNK_SIZE * CHUNK_SIZE;
pub const Coords = @Vector(3, i32);

coords: Coords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Block,

const Chunk = @This();

pub fn init(self: *Chunk, coords: Coords) void {
    self.coords = coords;
}

pub fn get(self: *Chunk, pos: Coords) Block {
    const i = @reduce(.Add, pos * Coords{ X_OFFSET, Y_OFFSET, Z_OFFSET });
    return self.blocks[@intCast(i)];
}

pub fn is_solid_face(self: *Chunk, pos: Coords, face: Block.Face) bool {
    const b = self.get_safe(pos);
    if (b == null) return false;
    return b.?.is_solid(face);
}

pub fn casts_ao(self: *Chunk, pos: Coords) bool {
    const b = self.get_safe(pos) orelse return false;
    return b.casts_ao();
}

pub fn get_safe(self: *Chunk, pos: Coords) ?Block {
    const size = Coords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE };
    const stride = Coords{ X_OFFSET, Y_OFFSET, Z_OFFSET };
    const zero = zm.vec.zero(3, i32);
    const a = pos < size;
    const b = pos >= zero;
    if (!@reduce(.And, a) or !@reduce(.And, b)) {
        return null;
    }

    const i = @reduce(.Add, pos * stride);
    return self.blocks[@intCast(i)];
}

pub fn set(self: *Chunk, pos: Coords, block: Block) void {
    const i = @reduce(.Add, pos * Coords{ X_OFFSET, Y_OFFSET, Z_OFFSET });
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
    const air = Block.air();
    const stone = Block.stone();
    const dirt = Block.dirt();
    const grass = Block.grass();

    @memset(&self.blocks, air);
    if (self.coords[1] > 0) return;
    if (self.coords[1] < 0) {
        @memset(&self.blocks, stone);
        return;
    }

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                const pos: Coords = @intCast(@Vector(3, usize){ x, y, z });
                switch (y) {
                    0...4 => self.set(pos, stone),
                    5...7 => self.set(pos, dirt),
                    8 => self.set(pos, grass),
                    else => self.set(pos, air),
                }
            }
        }
    }
}

fn generate_balls(self: *Chunk) void {
    const scale: zm.Vec3f = @splat(std.math.pi / 8.0);
    const size: Coords = @splat(CHUNK_SIZE);

    const air = Block.air();
    const stone = Block.stone();

    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            for (0..CHUNK_SIZE) |k| {
                const pos = Coords{
                    @intCast(i),
                    @intCast(j),
                    @intCast(k),
                } + self.coords * size;
                const xyz = @as(zm.Vec3f, @floatFromInt(pos)) * scale;

                const idx = i * X_OFFSET + j * Y_OFFSET + k * Z_OFFSET;
                const w = @abs(@sin(xyz[0]) + @cos(xyz[2]) + @sin(xyz[1]));

                if (w < 3 * 0.4) {
                    self.blocks[idx] = air;
                } else {
                    self.blocks[idx] = stone;
                }
            }
        }
    }
}

fn generate_checkers(self: *Chunk) void {
    const air = Block.air();
    const stone = Block.stone();
    const dirt = Block.dirt();

    @memset(&self.blocks, air);
    if (self.coords[1] > 0) return;

    if (@mod(@reduce(.Add, self.coords), 2) == 0) {
        @memset(&self.blocks, dirt);
    } else {
        @memset(&self.blocks, stone);
    }
}

fn generate_wavy(self: *Chunk) void {
    const air = Block.air();
    const stone = Block.stone();
    const dirt = Block.dirt();
    const grass = Block.grass();

    const scale = std.math.pi / 16.0;
    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |k| {
            const x: f32 = @floatFromInt(self.coords[0] * CHUNK_SIZE + @as(i32, @intCast(i)));
            const z: f32 = @floatFromInt(self.coords[2] * CHUNK_SIZE + @as(i32, @intCast(k)));
            const top: f32 = (@sin(x * scale) + @cos(z * scale)) * 4.0 + 8.0;

            for (0..CHUNK_SIZE) |j| {
                const pos = Coords{
                    @intCast(i),
                    @intCast(j),
                    @intCast(k),
                };
                const y: f32 = @floatFromInt(self.coords[1] *
                    CHUNK_SIZE +
                    @as(i32, @intCast(j)));

                var block: Block = air;
                if (y < top) block = grass;
                if (y + 1 < top) block = dirt;
                if (y + 3 < top) block = stone;
                self.set(pos, block);
            }
        }
    }
}

pub const neighbours: [6]Coords = .{
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
    .{ 1, 0, 0 },
    .{ -1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
};

const Neighbours = struct {
    n: [26]Coords = std.mem.zeroes([26]Coords),
    idx: [3][3][3]usize = std.mem.zeroes([3][3][3]usize),

    const instance: Neighbours = blk: {
        var self = Neighbours{};
        const zero: Coords = @splat(0);

        var l: usize = 0;
        for (0..3) |i| {
            for (0..3) |j| {
                for (0..3) |k| {
                    const pos: Coords = .{
                        @as(i32, @intCast(i)) - 1,
                        @as(i32, @intCast(j)) - 1,
                        @as(i32, @intCast(k)) - 1,
                    };
                    if (@reduce(.And, pos == zero)) continue;
                    self.n[l] = pos;
                    self.idx[i][j][k] = l;
                    l += 1;
                }
            }
        }

        break :blk self;
    };
};

pub const neighbours2 = Neighbours.instance.n;
pub const neighbours2_idx = Neighbours.instance.idx;

pub fn to_world_coord(pos: zm.Vec3f) Coords {
    return @intFromFloat(@floor(pos));
}

pub fn world_to_chunk(w: Coords) Coords {
    return @divFloor(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: Coords) Coords {
    return @mod(w, @as(Coords, @splat(CHUNK_SIZE)));
}
