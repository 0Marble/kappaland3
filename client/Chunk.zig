const std = @import("std");
const App = @import("App.zig");
const zm = @import("zm");
const Options = @import("Build").Options;
const Handle = @import("GpuAlloc.zig").Handle;
const Block = @import("Block.zig");
const ChunkManager = @import("ChunkManager.zig");
const Queue = @import("libmine").Queue;

pub const CHUNK_SIZE = 16;
pub const X_STRIDE = 1;
pub const Z_STRIDE = CHUNK_SIZE;
pub const Y_STRIDE = CHUNK_SIZE * CHUNK_SIZE;
pub const Coords = @Vector(3, i32);
const logger = std.log.scoped(.chunk);

// chunk lifetime
// these steps all happen exactly in this order (unless there are bugs in ChunkManager)
// and only after everything is complete the chunk may get invalidated
//
// init:
//      1. sets coords
//      3. state = not_ready
// generate:
//      1. sets blocks
//      2. this_chunk_lights is filled with light coordinates
// build_mesh:
//      1. sets is_occluded
//      2. sets neighbour_cache
//      3. faces is set on a thread-local arena
// move_mesh_from_thread_memory:
//      1. faces gets copied into a shared arena
// compute_light_sources:
//      1.
// after ChunkManager.process():
//      1. faces, is_occluded are copied to the gpu and invalidated
//      2. neighbour_cache may be invalid
//      3. coords, blocks are valid until the chunk gets unloaded
//      4. state = ready

coords: Coords,
state: State,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Block,

faces: [std.enums.values(Block.Direction).len]std.ArrayList(FaceMesh),
is_occluded: bool,
neighbour_cache: [Neighbours(3).NEIGHBOURS_CNT]?*Chunk,
this_chunk_lights_buf: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Coords,
light_sources: std.ArrayList(Coords),
outgoing_light: std.AutoArrayHashMapUnmanaged(LightMaterial, OutgoingLight),

const Chunk = @This();
pub const State = enum { not_ready, ready };

pub fn init(self: *Chunk, coords: Coords) void {
    @memset(&self.blocks, Block.air());
    self.coords = coords;
    self.state = .not_ready;
}

pub fn get(self: *Chunk, pos: Coords) Block {
    const i = @reduce(.Add, pos * Coords{ X_STRIDE, Y_STRIDE, Z_STRIDE });
    return self.blocks[@intCast(i)];
}

pub fn get_safe(self: *Chunk, pos: Coords) ?Block {
    const size = Coords{ CHUNK_SIZE, CHUNK_SIZE, CHUNK_SIZE };
    const stride = Coords{ X_STRIDE, Y_STRIDE, Z_STRIDE };
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
    const i = @reduce(.Add, pos * Coords{ X_STRIDE, Y_STRIDE, Z_STRIDE });
    self.blocks[@intCast(i)] = block;
}

pub fn generate(self: *Chunk) void {
    self.light_sources = .initBuffer(&self.this_chunk_lights_buf);

    const fptr = @field(Chunk, "generate_" ++ Options.world_gen);
    @call(.auto, fptr, .{self});
}

pub fn build_mesh(self: *Chunk, gpa: std.mem.Allocator) !void {
    self.faces = @splat(.empty);
    self.is_occluded = false;
    self.light_sources.clearRetainingCapacity();

    for (Neighbours(3).deltas, &self.neighbour_cache) |d, *n| {
        n.* = ChunkManager.instance().get_chunk(d + self.coords);
    }
    std.debug.assert(self.neighbour_cache[Neighbours(3).SELF_RELATIVE_IDX] == self);

    self.is_occluded &= self.next_layer_solid(.front, .{ 0, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.back, .{ CHUNK_SIZE - 1, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.right, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.left, .{ 0, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.top, .{ 0, CHUNK_SIZE - 1, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.bot, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                try self.mesh_block(gpa, .{ x, y, z });
            }
        }
    }
}

pub fn move_mesh_from_thread_memory(self: *Chunk, gpa: std.mem.Allocator) !void {
    var new_faces: @FieldType(Chunk, "faces") = @splat(.empty);
    for (&new_faces, self.faces) |*new, old| {
        new.* = try old.clone(gpa);
    }
    self.faces = new_faces;
}

pub fn compute_outgoing_light(self: *Chunk, gpa: std.mem.Allocator) !void {
    self.outgoing_light = .empty;
    var queue: Queue(Coords) = .empty;

    for (self.light_sources.items) |pos| {
        queue.clear();
        const color: u22 = @intCast(self.get(pos).emitted_light_color().?);
        const entry = try self.outgoing_light.getOrPut(gpa, color);
        if (!entry.found_existing) entry.value_ptr.* = .init(color);

        try self.compute_outgoing_light_from_block(gpa, pos, entry.value_ptr, &queue);
    }
}

fn compute_outgoing_light_from_block(
    self: *Chunk,
    gpa: std.mem.Allocator,
    start: Coords,
    mesh: *OutgoingLight,
    queue: *Queue(Coords),
) !void {
    const start_level = self.get(start).emitted_light_level().?;

    try queue.push(gpa, start);
    const ref = &mesh.verts[OutgoingLight.to_index(self.coords, start)];
    ref.level = start_level;

    while (queue.pop()) |pos| {
        const level = mesh.verts[OutgoingLight.to_index(self.coords, pos)].level;
        if (level == 1) continue;

        for (std.enums.values(Block.Direction)) |dir| {
            const next = pos + dir.front_dir();
            if (self.is_solid_face_relative(next, dir)) continue;
            const next_level = &mesh.verts[OutgoingLight.to_index(self.coords, next)].level;
            if (next_level.* < level - 1) {
                next_level.* = level - 1;
                try queue.push(gpa, next);
            }
        }
    }
}

fn mesh_block(self: *Chunk, gpa: std.mem.Allocator, xyz: @Vector(3, usize)) !void {
    const pos: Coords = @intCast(xyz);
    const block = self.get(pos);
    if (block.is_air()) return;
    var visible = false;

    for (std.enums.values(Block.Direction)) |side| {
        const front = side.front_dir();
        if (self.is_solid_face_relative(pos + front, side.flip())) continue;

        const up = side.up_dir();
        const down = -side.up_dir();
        const left = side.left_dir();
        const right = -side.left_dir();

        const ao = Ao.pack(
            @intFromBool(self.casts_ao_relative(pos + front + left)),
            @intFromBool(self.casts_ao_relative(pos + front + right)),
            @intFromBool(self.casts_ao_relative(pos + front + up)),
            @intFromBool(self.casts_ao_relative(pos + front + down)),
            @intFromBool(self.casts_ao_relative(pos + front + left + up)),
            @intFromBool(self.casts_ao_relative(pos + front + right + up)),
            @intFromBool(self.casts_ao_relative(pos + front + left + down)),
            @intFromBool(self.casts_ao_relative(pos + front + right + down)),
        );

        for (block.get_textures(side), block.get_faces(side)) |tex, face| {
            try self.faces[@intFromEnum(side)].append(gpa, .{
                .ao = @intCast(Ao.ao_to_idx[ao]),
                .model = @intCast(face),
                .texture = @intCast(tex),
                .x = @intCast(xyz[0]),
                .y = @intCast(xyz[1]),
                .z = @intCast(xyz[2]),
            });
        }
        visible = true;
    }

    if (visible and block.emits_light()) self.light_sources.appendAssumeCapacity(pos);
}

fn next_layer_solid(self: *Chunk, normal: Block.Direction, start: Coords) bool {
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

            if (!self.is_solid_face_relative(pos + front, normal.flip())) return false;
        }
    }

    return true;
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

                const idx = i * X_STRIDE + j * Y_STRIDE + k * Z_STRIDE;
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

fn get_neighbour(self: *Chunk, coords: Coords) ?*Chunk {
    return self.neighbour_cache[Neighbours(3).neighbour_index(self.coords, coords)];
}

fn is_solid_face_relative(self: *Chunk, pos: Coords, face: Block.Direction) bool {
    const world = world_from_chunk_and_block(self.coords, pos);
    const chunk = world_to_chunk(world);
    const block = world_to_block(world);

    if (self.get_neighbour(chunk)) |other| return other.get(block).is_solid(face);
    return false;
}

fn casts_ao_relative(self: *Chunk, pos: Coords) bool {
    const world = world_from_chunk_and_block(self.coords, pos);
    const chunk = world_to_chunk(world);
    const block = world_to_block(world);

    if (self.get_neighbour(chunk)) |other| return other.get(block).casts_ao();
    return false;
}

pub fn to_world_coord(pos: zm.Vec3f) Coords {
    return @intFromFloat(@floor(pos));
}

pub fn world_to_chunk(w: Coords) Coords {
    return @divFloor(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: Coords) Coords {
    return @mod(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_from_chunk_and_block(chunk: Coords, block: Coords) Coords {
    const size: Coords = @splat(CHUNK_SIZE);
    return block + chunk * size;
}

pub const FaceMesh = packed struct(u64) {
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

pub fn Neighbours(comptime size: comptime_int) type {
    std.debug.assert(size > 0);
    std.debug.assert(size % 2 == 1);
    const half_size: Coords = .{ size / 2, size / 2, size / 2 };

    const deltas_arr, const to_idx_arr = blk: {
        var deltas_arr = std.mem.zeroes([size * size * size]Coords);
        var to_idx_arr = std.mem.zeroes([size][size][size]usize);
        var cnt: usize = 0;

        for (0..size) |x| {
            for (0..size) |y| {
                for (0..size) |z| {
                    deltas_arr[cnt] = @intCast(@as(@Vector(3, usize), .{ x, y, z }));
                    deltas_arr[cnt] -= half_size;
                    to_idx_arr[x][y][z] = cnt;
                    cnt += 1;
                }
            }
        }
        break :blk .{ deltas_arr, to_idx_arr };
    };

    return struct {
        pub const deltas = deltas_arr;
        pub const to_idx = to_idx_arr;
        pub const NEIGHBOURS_CNT = size * size * size;
        pub const SELF_RELATIVE_IDX = neighbour_index(@splat(0), @splat(0));

        pub fn neighbour_index(origin: Coords, chunk: Coords) usize {
            const delta = chunk - origin + half_size;
            const i: usize = @intCast(delta[0]);
            const j: usize = @intCast(delta[1]);
            const k: usize = @intCast(delta[2]);
            return to_idx[i][j][k];
        }

        pub fn block_neighbour_index(origin: Coords, block: Coords) usize {
            const chunk = world_to_chunk(world_from_chunk_and_block(origin, block));
            return neighbour_index(origin, chunk);
        }
    };
}

const LightMaterial = u28;
const LightLevel = u4;
const BlockLighting = packed struct(u32) {
    light_material: LightMaterial,
    level: LightLevel = 0,
};

const OutgoingLight = struct {
    material: LightMaterial,
    verts: [(3 * CHUNK_SIZE) * (3 * CHUNK_SIZE) * (3 * CHUNK_SIZE)]BlockLighting,

    pub fn init(material: LightMaterial) OutgoingLight {
        return .{
            .material = material,
            .verts = @splat(.{ .light_material = material }),
        };
    }

    const CHUNK_STRIDE = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;

    fn to_index(origin: Coords, pos: Coords) usize {
        const world = world_from_chunk_and_block(origin, pos);
        const block = world_to_block(world);
        const chunk = world_to_chunk(world);
        const chunk_idx = Neighbours(3).neighbour_index(origin, chunk);
        const size: Coords = .{ X_STRIDE, Y_STRIDE, Z_STRIDE };
        return chunk_idx * CHUNK_STRIDE + @as(usize, @intCast(@reduce(.Add, block * size)));
    }
};
