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
    self.is_occluded &= self.next_layer_solid(.bot, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
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
            CHUNK_SIZE - 1,
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
    ao: u6,
    model: u10 = 0,
    _unused2: u4 = 0b1010,
    // B:
    texture: u16,
    _unused3: u16 = 0xdead,

    pub fn define() [:0]const u8 {
        return 
        \\
        \\struct Face {
        \\  uvec3 pos;
        \\  uint ao;
        \\  uint model;
        \\  uint texture;
        \\};
        \\
        \\Face unpack_face(){
        \\  uint x = (vert_face_a >> uint(0)) & uint(0x0F);
        \\  uint y = (vert_face_a >> uint(4)) & uint(0x0F);
        \\  uint z = (vert_face_a >> uint(8)) & uint(0x0F);
        \\  uint ao = (vert_face_a >> uint(12)) & uint(0x3F);
        \\  uint model = (vert_face_a >> uint(18)) & uint(0x3FF);
        \\  uint tex = (vert_face_b >> uint(0)) & uint(0xFFFF);
        \\  return Face(uvec3(x, y, z), ao, model, tex);
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

            if (!self.is_solid_neighbour_face(pos + front, normal.flip())) return false;
        }
    }

    return true;
}

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

            const block = self.chunk.get(pos);
            if (block.is_air() or self.is_solid_neighbour_face(pos + front, normal.flip())) {
                continue;
            }

            const ao = Ao.pack(
                @intFromBool(self.is_solid_neighbour(pos + front + left)),
                @intFromBool(self.is_solid_neighbour(pos + front + right)),
                @intFromBool(self.is_solid_neighbour(pos + front + up)),
                @intFromBool(self.is_solid_neighbour(pos + front + down)),
                @intFromBool(self.is_solid_neighbour(pos + front + left + up)),
                @intFromBool(self.is_solid_neighbour(pos + front + right + up)),
                @intFromBool(self.is_solid_neighbour(pos + front + left + down)),
                @intFromBool(self.is_solid_neighbour(pos + front + right + down)),
            );

            for (block.get_textures(normal), block.get_model(normal)) |t, m| {
                const face = Face{
                    .x = @intCast(pos[0]),
                    .y = @intCast(pos[1]),
                    .z = @intCast(pos[2]),
                    .ao = @intCast(Ao.ao_to_idx[ao]),
                    .model = @intCast(m),
                    .texture = @intCast(t),
                };
                try self.faces[@intFromEnum(normal)].append(gpa, face);
            }
        }
    }
}

pub const Ao = struct {
    const ao_to_idx = precalculated[1];
    pub const idx_to_ao = precalculated[0];

    const L = 0;
    const R = 1;
    const T = 2;
    const B = 3;
    const TL = 4;
    const TR = 5;
    const BL = 6;
    const BR = 7;

    fn normalize(x: u8) u8 {
        const l = (x >> L) & 1;
        const r = (x >> R) & 1;
        const t = (x >> T) & 1;
        const b = (x >> B) & 1;
        const tl = (x >> TL) & 1;
        const tr = (x >> TR) & 1;
        const bl = (x >> BL) & 1;
        const br = (x >> BR) & 1;
        return pack(l, r, t, b, tl, tr, bl, br);
    }

    fn pack(l: u8, r: u8, t: u8, b: u8, tl: u8, tr: u8, bl: u8, br: u8) u8 {
        return (l << L) |
            (r << R) |
            (t << T) |
            (b << B) |
            ((tl * (1 - l) * (1 - t)) << TL) |
            ((tr * (1 - r) * (1 - t)) << TR) |
            ((bl * (1 - l) * (1 - b)) << BL) |
            ((br * (1 - r) * (1 - b)) << BR);
    }

    const precalculated = blk: {
        @setEvalBranchQuota(std.math.maxInt(u32));
        const UNIQUE_CNT = 47;
        var to_ao: [UNIQUE_CNT]u8 = @splat(0);
        var to_idx: [256]u8 = @splat(0);

        var i: usize = 0;
        for (0..256) |x| {
            const y = normalize(x);
            const k = l1: for (0..i) |j| {
                if (to_ao[j] == y) break :l1 j;
            } else l2: {
                to_ao[i] = y;
                i += 1;
                break :l2 i - 1;
            };
            to_idx[x] = k;
        }
        std.debug.assert(i == UNIQUE_CNT);
        break :blk .{ to_ao, to_idx };
    };

    pub fn define() [:0]const u8 {
        return std.fmt.comptimePrint(
            \\
            \\float get_ao() {{
            \\  #define GET(dir) float((frag_ao >> uint(dir)) & uint(1))
            \\  #define CORNER(v) (1.0 - clamp(abs(frag_uv.x - (v).x) + abs(frag_uv.y - (v).y), 0, 1))
            \\  float l = GET({}) * (1.0 - frag_uv.x);
            \\  float r = GET({}) * (frag_uv.x);
            \\  float t = GET({}) * (frag_uv.y);
            \\  float b = GET({}) * (1.0 - frag_uv.y);
            \\  float tl = GET({}) * CORNER(vec2(0, 1));
            \\  float tr = GET({}) * CORNER(vec2(1, 1));
            \\  float bl = GET({}) * CORNER(vec2(0, 0));
            \\  float br = GET({}) * CORNER(vec2(1, 0));
            \\  float ao = (l + r + t + b + tl + tr + bl + br) / 4.0;
            \\  return smoothstep(0.0, 1.0, ao);
            \\  #undef GET
            \\  #undef CORNER
            \\}}
        , .{ Ao.L, Ao.R, Ao.T, Ao.B, Ao.TL, Ao.TR, Ao.BL, Ao.BR });
    }
};

fn is_solid_neighbour(self: *Mesh, pos: Coords) bool {
    const world = self.chunk.coords * Chunk.Coords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE } + pos;
    const chunk = Chunk.world_to_chunk(world);
    const block = Chunk.world_to_block(world);
    if (@reduce(.And, chunk == self.chunk.coords)) return self.chunk.is_solid(block);

    const d = chunk - self.chunk.coords;
    const i: usize = @intCast(d[0] + 1);
    const j: usize = @intCast(d[1] + 1);
    const k: usize = @intCast(d[2] + 1);
    const idx = Chunk.neighbours2_idx[i][j][k];
    std.debug.assert(@reduce(.And, Chunk.neighbours2[idx] == d));
    if (self.neighbour_cache[idx]) |other| return other.is_solid(block);
    return false;
}

fn is_solid_neighbour_face(self: *Mesh, pos: Coords, face: Block.Face) bool {
    const world = self.chunk.coords * Chunk.Coords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE } + pos;
    const chunk = Chunk.world_to_chunk(world);
    const block = Chunk.world_to_block(world);
    if (@reduce(.And, chunk == self.chunk.coords)) return self.chunk.is_solid_face(block, face);

    const d = chunk - self.chunk.coords;
    const i: usize = @intCast(d[0] + 1);
    const j: usize = @intCast(d[1] + 1);
    const k: usize = @intCast(d[2] + 1);
    const idx = Chunk.neighbours2_idx[i][j][k];
    std.debug.assert(@reduce(.And, Chunk.neighbours2[idx] == d));
    if (self.neighbour_cache[idx]) |other| return other.is_solid_face(block, face);
    return false;
}
