const std = @import("std");
const App = @import("App.zig");
const zm = @import("zm");
const Options = @import("ClientOptions");
const Handle = @import("GpuAlloc.zig").Handle;
const Block = @import("Block.zig");
const ChunkManager = @import("ChunkManager.zig");

pub const CHUNK_SIZE = 16;
pub const X_OFFSET = 1;
pub const Z_OFFSET = CHUNK_SIZE;
pub const Y_OFFSET = CHUNK_SIZE * CHUNK_SIZE;
pub const Coords = @Vector(3, i32);

coords: Coords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Block.Id,
faces: ?[]const Face,
occlusion: OcclusionMask,

cache_valid: bool,
neighbours_cache: [6]?*Chunk,
neighbours2_cache: [26]?*Chunk,
is_occluded: bool,

const Chunk = @This();

pub fn init(self: *Chunk, coords: Coords) void {
    self.coords = coords;
    self.cache_valid = false;
    self.faces = null;
    self.occlusion = .{};
}

pub fn get(self: *Chunk, pos: Coords) Block.Id {
    const i = @reduce(.Add, pos * Coords{ X_OFFSET, Y_OFFSET, Z_OFFSET });
    return self.blocks[@intCast(i)];
}

pub fn is_solid(self: *Chunk, pos: Coords) bool {
    const b = self.get_safe(pos);
    if (b == null or b == .air) return false;
    return true;
}

pub fn get_safe(self: *Chunk, pos: Coords) ?Block.Id {
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

pub fn set(self: *Chunk, pos: Coords, block: Block.Id) void {
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
    @memset(&self.blocks, .air);
    if (self.coords[1] > 0) return;
    if (self.coords[1] < 0) {
        @memset(&self.blocks, .stone);
        return;
    }

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |z| {
            for (0..CHUNK_SIZE) |y| {
                const pos: Coords = @intCast(@Vector(3, usize){ x, y, z });
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
    const size: Coords = @splat(CHUNK_SIZE);

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
                const pos = Coords{
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

pub fn bounding_sphere(self: *Chunk) zm.Vec4f {
    const size: zm.Vec3f = @splat(CHUNK_SIZE);
    const coords: zm.Vec3f = @floatFromInt(self.coords);
    const pos = coords * size + size * @as(zm.Vec3f, @splat(0.5));
    const rad: f32 = @as(f32, @floatFromInt(CHUNK_SIZE)) * @sqrt(3.0) / 2.0;

    return .{ pos[0], pos[1], pos[2], rad };
}

pub const neighbours: [6]Coords = .{
    .{ 0, 0, 1 },
    .{ 0, 0, -1 },
    .{ 1, 0, 0 },
    .{ -1, 0, 0 },
    .{ 0, 1, 0 },
    .{ 0, -1, 0 },
};

pub const neighbours2 = blk: {
    var res = std.mem.zeroes([26]Coords);
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
                res[l] = pos;
                l += 1;
            }
        }
    }

    break :blk res;
};

pub fn build_mesh(self: *Chunk, faces: *std.array_list.Managed(Face)) !void {
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ 0, 0, @intCast(i) };
        self.occlusion.front = try self.build_layer_mesh(.front, start, faces);
    }
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{
            CHUNK_SIZE - 1,
            0,
            @intCast(CHUNK_SIZE - 1 - i),
        };
        self.occlusion.back = try self.build_layer_mesh(.back, start, faces);
    }
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ @intCast(i), 0, CHUNK_SIZE - 1 };
        self.occlusion.right = try self.build_layer_mesh(.right, start, faces);
    }
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ @intCast(CHUNK_SIZE - 1 - i), 0, 0 };
        self.occlusion.left = try self.build_layer_mesh(.left, start, faces);
    }
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ 0, @intCast(i), 0 };
        self.occlusion.top = try self.build_layer_mesh(.top, start, faces);
    }
    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{
            CHUNK_SIZE - 1,
            @intCast(CHUNK_SIZE - 1 - i),
            0,
        };
        self.occlusion.bot = try self.build_layer_mesh(.bot, start, faces);
    }
}

const ao_mask: [6][4]u4 = .{
    .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // front
    .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // back
    .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // right
    .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // left
    .{ 0b1000, 0b0100, 0b0010, 0b0001 }, // top
    .{ 0b1000, 0b0100, 0b0010, 0b0001 }, // bot
};

fn build_layer_mesh(
    self: *Chunk,
    normal: Block.Face,
    start: Coords,
    faces: *std.array_list.Managed(Face),
) !bool {
    const right = -normal.left_dir();
    const left = -right;
    const up = normal.up_dir();
    const down = -up;
    const front = normal.front_dir();

    var is_full_layer = true;

    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            const u: i32 = @intCast(i);
            const v: i32 = @intCast(j);

            const pos = start +
                @as(Coords, @splat(u)) * right +
                @as(Coords, @splat(v)) * up;

            const block = self.get(pos);
            if (block == .air or self.is_solid(pos + front)) {
                is_full_layer = false;
                continue;
            }
            if (self.is_solid_maybe_neighbour(pos + front)) {
                continue;
            }

            var ao: u4 = 0;
            const ao_idx: usize = @intFromEnum(normal);
            if (self.is_solid_maybe_neighbour(pos + front + left)) ao |= ao_mask[ao_idx][0];
            if (self.is_solid_maybe_neighbour(pos + front + right)) ao |= ao_mask[ao_idx][1];
            if (self.is_solid_maybe_neighbour(pos + front + up)) ao |= ao_mask[ao_idx][2];
            if (self.is_solid_maybe_neighbour(pos + front + down)) ao |= ao_mask[ao_idx][3];

            const face = Face{
                .x = @intCast(pos[0]),
                .y = @intCast(pos[1]),
                .z = @intCast(pos[2]),
                .normal = @intFromEnum(normal),
                .ao = ao,
            };

            try faces.append(face);
        }
    }

    return is_full_layer;
}

pub fn ensure_neighbours(self: *Chunk) void {
    if (self.cache_valid) return;

    const store = &ChunkManager.instance().chunks;
    for (neighbours2, &self.neighbours2_cache) |d, *ch| {
        ch.* = store.get(d + self.coords);
    }
    for (neighbours, &self.neighbours_cache) |d, *ch| {
        ch.* = store.get(d + self.coords);
    }
    self.cache_valid = true;
}

fn is_solid_maybe_neighbour(self: *Chunk, pos: Coords) bool {
    if (self.get_safe(pos)) |_| return self.is_solid(pos);
    const chunk = world_to_chunk(pos) + self.coords;
    const block = world_to_block(pos);

    std.debug.assert(self.cache_valid);
    for (self.neighbours2_cache) |n| {
        const other = n orelse continue;
        if (@reduce(.And, other.coords == chunk)) return other.is_solid(block);
    }
    return false;
}

pub fn cache_occluded(self: *Chunk) void {
    std.debug.assert(self.cache_valid);
    for (self.neighbours_cache, std.meta.tags(Block.Face)) |o, dir| {
        const other = o orelse {
            self.is_occluded = false;
            return;
        };
        const occluded = other.occludes(dir.flip());
        if (!occluded) {
            self.is_occluded = false;
            return;
        }
    }
    self.is_occluded = true;
}

fn occludes(self: *Chunk, dir: Block.Face) bool {
    switch (dir) {
        inline else => |tag| return @field(self.occlusion, @tagName(tag)) == true,
    }
}

const OcclusionMask = packed struct {
    front: bool = false,
    back: bool = false,
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bot: bool = false,
};

pub const Face = packed struct(u64) {
    // A:
    x: u4,
    y: u4,
    z: u4,
    normal: u3,
    _unused1: u1 = 0,
    ao: u4,
    _unused2: u12 = 0xeba,
    // B:
    _unused3: u32 = 0xdeadbeef,

    pub fn define() [:0]const u8 {
        return 
        \\struct Face {
        \\  uvec3 pos;
        \\  uint n;
        \\  uint ao;
        \\};
        \\
        \\Face unpack(){
        \\  uint x = (vert_face_a >> uint(0)) & uint(0x0F);
        \\  uint y = (vert_face_a >> uint(4)) & uint(0x0F);
        \\  uint z = (vert_face_a >> uint(8)) & uint(0x0F);
        \\  uint n = (vert_face_a >> uint(12)) & uint(0x0F);
        \\  uint ao = (vert_face_a >> uint(16)) & uint(0x0F);
        \\  return Face(uvec3(x, y, z), n, ao);
        \\}
        ;
    }
};

pub fn to_world_coord(pos: zm.Vec3f) Coords {
    return @intFromFloat(@floor(pos));
}

pub fn world_to_chunk(w: Coords) Coords {
    return @divFloor(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: Coords) Coords {
    return @mod(w, @as(Coords, @splat(CHUNK_SIZE)));
}
