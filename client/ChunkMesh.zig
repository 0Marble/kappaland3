const Chunk = @import("Chunk.zig");
const std = @import("std");
const CHUNK_SIZE = Chunk.CHUNK_SIZE;
const Coords = Chunk.Coords;
const Block = @import("Block.zig");
const Game = @import("Game.zig");

chunk: *Chunk,
faces: [std.enums.values(Block.Face).len]std.ArrayList(Face),

neighbour_cache: [26]?*Chunk,
is_occluded: bool,

const Mesh = @This();
const OOM = std.mem.Allocator.Error;

pub fn build(chunk: *Chunk, gpa: std.mem.Allocator) !Mesh {
    var self = Mesh{
        .chunk = chunk,
        .faces = @splat(.empty),
        .neighbour_cache = @splat(null),
        .is_occluded = true,
    };

    for (Chunk.neighbours2, &self.neighbour_cache) |d, *n| {
        n.* = Game.instance().chunk_manager.get_chunk(d + chunk.coords);
    }

    self.is_occluded &= self.next_layer_solid(.front, .{ 0, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.back, .{ CHUNK_SIZE - 1, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.right, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.left, .{ 0, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.top, .{ 0, CHUNK_SIZE - 1, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.bot, .{ CHUNK_SIZE - 1, 0, 0 });
    if (self.is_occluded) return self;

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ 0, 0, @intCast(i) };
        try self.build_layer_mesh(.front, start, gpa);
    }

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{
            CHUNK_SIZE - 1,
            0,
            @intCast(CHUNK_SIZE - 1 - i),
        };
        try self.build_layer_mesh(.back, start, gpa);
    }

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ @intCast(i), 0, CHUNK_SIZE - 1 };
        try self.build_layer_mesh(.right, start, gpa);
    }

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ @intCast(CHUNK_SIZE - 1 - i), 0, 0 };
        try self.build_layer_mesh(.left, start, gpa);
    }

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{ 0, @intCast(i), CHUNK_SIZE - 1 };
        try self.build_layer_mesh(.top, start, gpa);
    }

    for (0..CHUNK_SIZE) |i| {
        const start: Coords = .{
            CHUNK_SIZE - 1,
            @intCast(CHUNK_SIZE - 1 - i),
            0,
        };
        try self.build_layer_mesh(.bot, start, gpa);
    }

    return self;
}

pub fn dupe(self: *const Mesh, gpa: std.mem.Allocator) OOM!Mesh {
    var new_mesh = self.*;
    for (&new_mesh.faces, self.faces) |*new, old| {
        new.* = try old.clone(gpa);
    }
    return new_mesh;
}

pub const Face = packed struct(u64) {
    // A:
    x: u4,
    y: u4,
    z: u4,
    ao: u8,
    u_offset: u2 = 0,
    v_offset: u2 = 0,
    w_offset: u2 = 0,
    u_size: u2 = 3,
    v_size: u2 = 3,
    _unused2: u2 = 2,
    // B:
    texture: u16,
    _unused3: u16 = 0xdead,

    pub fn define() [:0]const u8 {
        return 
        \\struct Face {
        \\  uvec3 pos;
        \\  vec3 offset;
        \\  vec2 size;
        \\  uint ao;
        \\  uint texture;
        \\};
        \\
        \\Face unpack(){
        \\  uint x = (vert_face_a >> uint(0)) & uint(0x0F);
        \\  uint y = (vert_face_a >> uint(4)) & uint(0x0F);
        \\  uint z = (vert_face_a >> uint(8)) & uint(0x0F);
        \\  uint ao = (vert_face_a >> uint(12)) & uint(0xFF);
        \\  uint u = (vert_face_a >> uint(20)) & uint(0x3);
        \\  uint v = (vert_face_a >> uint(22)) & uint(0x3);
        \\  uint w = (vert_face_a >> uint(24)) & uint(0x3);
        \\  uint s = (vert_face_a >> uint(26)) & uint(0x3);
        \\  uint t = (vert_face_a >> uint(28)) & uint(0x3);
        \\
        \\  uint tex = (vert_face_b >> uint(0)) & uint(0xFFFF);
        \\  vec3 offset = vec3(u, v, w) / 4.0;
        \\  vec2 size = vec2(s + 1, t + 1) / 4.0;
        \\  return Face(uvec3(x, y, z), offset, size, ao, tex);
        \\}
        ;
    }
};

fn next_layer_solid(self: *Mesh, normal: Block.Face, start: Coords) bool {
    const right = -normal.left_dir();
    const up = normal.up_dir();
    const front = normal.front_dir();

    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            const u: i32 = @intCast(i);
            const v: i32 = @intCast(j);

            const pos = start +
                @as(Coords, @splat(u)) * right +
                @as(Coords, @splat(v)) * up;

            if (!self.is_solid_neighbour(pos + front)) return false;
        }
    }

    return true;
}

const ao_mask: [6][8]u8 = .{
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // front
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // back
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // right
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // left
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // top
    .{
        0b00001000, 0b00000100, 0b00000010, 0b00000001,
        0b00010000, 0b00100000, 0b01000000, 0b10000000,
    }, // bot
};

fn build_layer_mesh(
    self: *Mesh,
    normal: Block.Face,
    start: Coords,
    gpa: std.mem.Allocator,
) !void {
    const right = -normal.left_dir();
    const left = -right;
    const up = normal.up_dir();
    const down = -up;
    const front = normal.front_dir();

    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            const u: i32 = @intCast(i);
            const v: i32 = @intCast(j);

            const pos = start +
                @as(Coords, @splat(u)) * right +
                @as(Coords, @splat(v)) * up;

            if (!self.is_solid(pos) or self.is_solid_neighbour(pos + front)) {
                continue;
            }

            var ao: u8 = 0;
            const ao_idx: usize = @intFromEnum(normal);
            if (self.is_solid_neighbour(pos + front + left)) ao |= ao_mask[ao_idx][0];
            if (self.is_solid_neighbour(pos + front + right)) ao |= ao_mask[ao_idx][1];
            if (self.is_solid_neighbour(pos + front + up)) ao |= ao_mask[ao_idx][2];
            if (self.is_solid_neighbour(pos + front + down)) ao |= ao_mask[ao_idx][3];

            if (self.is_solid_neighbour(pos + front + left + up)) ao |= ao_mask[ao_idx][4];
            if (self.is_solid_neighbour(pos + front + right + up)) ao |= ao_mask[ao_idx][5];
            if (self.is_solid_neighbour(pos + front + left + down)) ao |= ao_mask[ao_idx][6];
            if (self.is_solid_neighbour(pos + front + right + down)) ao |= ao_mask[ao_idx][7];

            const block = self.chunk.get(pos);
            const face = Face{
                .x = @intCast(pos[0]),
                .y = @intCast(pos[1]),
                .z = @intCast(pos[2]),
                .ao = ao,
                .texture = @intCast(block.get_texture(normal)),
            };

            try self.faces[@intFromEnum(normal)].append(gpa, face);
        }
    }
}

inline fn is_solid(self: *Mesh, pos: Coords) bool {
    return self.chunk.is_solid(pos);
}

fn is_solid_neighbour(self: *Mesh, pos: Coords) bool {
    const world = self.chunk.coords * Chunk.Coords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE } + pos;
    const chunk = Chunk.world_to_chunk(world);
    const block = Chunk.world_to_block(world);
    if (@reduce(.And, chunk == self.chunk.coords)) return self.is_solid(block);

    const d = chunk - self.chunk.coords;
    const i: usize = @intCast(d[0] + 1);
    const j: usize = @intCast(d[1] + 1);
    const k: usize = @intCast(d[2] + 1);
    const idx = Chunk.neighbours2_idx[i][j][k];
    std.debug.assert(@reduce(.And, Chunk.neighbours2[idx] == d));
    if (self.neighbour_cache[idx]) |other| return other.is_solid(block);
    return false;
}
