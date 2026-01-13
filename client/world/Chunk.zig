const std = @import("std");
const Block = @import("../Block.zig");
const World = @import("../World.zig");
const Options = @import("Build").Options;
const BlockRenderer = @import("BlockRenderer.zig");
const ChunkManager = @import("ChunkManager.zig");
const Queue = @import("libmine").Queue;

const Chunk = @This();
const Coords = World.Coords;
pub const CHUNK_SIZE = 16;

const X_STRIDE = 1;
const Z_STRIDE = CHUNK_SIZE;
const Y_STRIDE = CHUNK_SIZE * CHUNK_SIZE;
const BLOCK_STRIDE: @Vector(3, i32) = .{ X_STRIDE, Y_STRIDE, Z_STRIDE };
const SIZE: @Vector(3, i32) = @splat(CHUNK_SIZE);

world: *World,
coords: Coords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Block = undefined,
neighbours: std.enums.EnumMap(Block.Direction, *Chunk) = .init(.{}),
is_occluded: bool = false,
light_sources: std.AutoArrayHashMapUnmanaged(Coords, void) = .empty,
light_levels: std.AutoArrayHashMapUnmanaged(LightColor, LightLevels) = .empty,
faces: std.EnumArray(Block.Direction, std.ArrayList(BlockRenderer.FaceMesh)) = .initFill(.empty),

const OOM = std.mem.Allocator.Error;
pub fn init(world: *World, coords: Coords) OOM!*Chunk {
    const self: *Chunk = try world.chunk_pool.create();
    self.* = Chunk{ .coords = coords, .world = world };

    for (std.enums.values(Block.Direction)) |dir| {
        if (world.chunks.get(coords + dir.front_dir())) |other| {
            self.neighbours.put(dir, other);
            other.neighbours.put(dir.flip(), self);
        }
    }
    return self;
}

pub fn deinit(self: *Chunk, shared_gpa: std.mem.Allocator) void {
    var it = self.neighbours.iterator();
    while (it.next()) |entry| {
        const dir = entry.key;
        const other = entry.value.*;
        other.neighbours.remove(dir);
    }
    for (&self.faces.values) |*faces| {
        faces.deinit(shared_gpa);
    }
    self.light_sources.deinit(shared_gpa);
    self.light_levels.deinit(shared_gpa);
}

pub fn generate(self: *Chunk, worker: *ChunkManager.Worker) OOM!void {
    _ = worker;
    if (self.coords[1] > 0) {
        @memset(&self.blocks, Block.air());
        return;
    } else if (self.coords[1] < 0) {
        @memset(&self.blocks, Block.stone());
        return;
    }

    for (0..CHUNK_SIZE) |y| {
        for (0..CHUNK_SIZE) |x| {
            for (0..CHUNK_SIZE) |z| {
                const pos: Coords = @intCast(@Vector(3, usize){ x, y, z });
                const block = switch (y) {
                    0...4 => Block.stone(),
                    5...7 => Block.dirt(),
                    8 => if (x == 0 or x + 1 == CHUNK_SIZE or z == 0 or z + 1 == CHUNK_SIZE)
                        Block.planks()
                    else
                        Block.grass(),
                    else => Block.air(),
                };
                self.set(pos, block);
            }
        }
    }
}

pub fn build_mesh(self: *Chunk, worker: *ChunkManager.Worker) OOM!void {
    for (&self.faces.values) |*faces| faces.clearAndFree(worker.shared());

    // self.is_occluded &= self.next_layer_solid(.front, .{ 0, 0, CHUNK_SIZE - 1 });
    // self.is_occluded &= self.next_layer_solid(.back, .{ CHUNK_SIZE - 1, 0, 0 });
    // self.is_occluded &= self.next_layer_solid(.right, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    // self.is_occluded &= self.next_layer_solid(.left, .{ 0, 0, 0 });
    // self.is_occluded &= self.next_layer_solid(.top, .{ 0, CHUNK_SIZE - 1, CHUNK_SIZE - 1 });
    // self.is_occluded &= self.next_layer_solid(.bot, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    // if (self.is_occluded) return;

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                try self.mesh_block(.{ x, y, z }, worker);
            }
        }
    }

    for (&self.faces.values) |*faces| faces.* = try faces.clone(worker.shared());
}

pub fn set_block_and_propagate_updates(
    self: *Chunk,
    pos: Coords,
    block: Block,
    worker: *ChunkManager.Worker,
) OOM!void {
    std.debug.assert(worker.is_main_thread());
    self.set(pos, block);

    var queue = PropagateLightQueue.empty;
    defer queue.deinit(worker.temp());

    if (block.emits_light()) {
        try self.propagate_light(pos, &queue, worker);
    }

    for (self.light_levels.values()) |*light_levels| {
        if (block.emitted_light_color() == light_levels.color) continue;
        try self.propagate_dark(pos, light_levels.color, &queue, worker);
    }
}

fn set(self: *Chunk, pos: Coords, block: Block) void {
    const idx: usize = @intCast(@reduce(.Add, pos * BLOCK_STRIDE));
    self.blocks[idx] = block;
}

pub fn get(self: *Chunk, pos: Coords) Block {
    const idx: usize = @intCast(@reduce(.Add, pos * BLOCK_STRIDE));
    return self.blocks[idx];
}

// get a chunk at tgt_coords given this chunk,
// may be faster then normal hashmap lookup due to caching
// the order of traversal doesnt matter since loaded region is
// always a rect
pub fn get_chunk(self: *Chunk, chunk_coords: Coords) ?*Chunk {
    const CHUNK_NEAR = 10;
    var delta = chunk_coords - self.coords;
    if (@reduce(.Add, delta) > CHUNK_NEAR) return self.world.chunks.get(chunk_coords);

    var cur = self;

    const one_x: Coords = .{ 1, 0, 0 };
    const one_y: Coords = .{ 0, 1, 0 };
    const one_z: Coords = .{ 0, 0, 1 };

    while (delta[0] != 0) {
        if (delta[0] > 0) {
            cur = cur.neighbours.get(.right) orelse return null;
            delta -= one_x;
        } else {
            cur = cur.neighbours.get(.left) orelse return null;
            delta += one_x;
        }
    }

    while (delta[1] != 0) {
        if (delta[1] > 0) {
            cur = cur.neighbours.get(.top) orelse return null;
            delta -= one_y;
        } else {
            cur = cur.neighbours.get(.bot) orelse return null;
            delta += one_y;
        }
    }

    while (delta[2] != 0) {
        if (delta[2] > 0) {
            cur = cur.neighbours.get(.front) orelse return null;
            delta -= one_z;
        } else {
            cur = cur.neighbours.get(.back) orelse return null;
            delta += one_z;
        }
    }

    return cur;
}

pub fn get_chunk_block(self: *Chunk, block_coords: Coords) ?struct { *Chunk, Coords } {
    const global = self.coords * SIZE + block_coords;
    const chunk_coords = World.world_to_chunk(global);
    if (self.get_chunk(chunk_coords)) |chunk| {
        const block = World.world_to_block(global);
        return .{ chunk, block };
    } else return null;
}

pub fn get_light_level(self: *Chunk, block: Coords, color: LightColor) ?LightLevelInfo {
    const levels = self.light_levels.getPtr(color) orelse return null;
    const idx: usize = @intCast(@reduce(.Add, block * BLOCK_STRIDE));
    return levels.levels[idx];
}

const LightColor = u12;
const LightLevelInfo = u4;
const LightLevels = struct {
    color: LightColor,
    levels: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]LightLevelInfo,

    fn init(color: LightColor) LightLevels {
        return .{
            .color = color,
            .levels = @splat(0),
        };
    }
};

const PropagateLightQueue = Queue(struct { *Chunk, Coords, u4 });
fn propagate_light(
    self: *Chunk,
    start: Coords,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
) OOM!void {
    std.debug.assert(worker.is_main_thread());
    const color = self.get(start).emitted_light_color().?;
    try queue.push(worker.temp(), .{ self, start, self.get(start).emitted_light_level().? });

    while (queue.pop()) |cur| {
        const chunk, const pos, const level = cur;
        const light_levels = blk: {
            const entry = try chunk.light_levels.getOrPut(worker.shared(), color);
            if (!entry.found_existing) entry.value_ptr.* = .init(color);
            break :blk entry.value_ptr;
        };

        const idx: usize = @intCast(@reduce(.Add, pos * BLOCK_STRIDE));
        if (light_levels.levels[idx] > level) continue;
        light_levels.levels[idx] = level;
        if (level == 1) continue;

        for (std.enums.values(Block.Direction)) |dir| {
            const next = chunk.get_chunk_block(pos + dir.front_dir()) orelse continue;
            const next_chunk, const next_pos = next;
            if (!next_chunk.get(next_pos).is_air()) continue;
            try queue.push(worker.temp(), .{ next_chunk, next_pos, level - 1 });
        }
    }
}

fn propagate_dark(
    self: *Chunk,
    start: Coords,
    color: LightColor,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
) OOM!void {
    std.debug.assert(worker.is_main_thread());

    {
        const light_levels = self.light_levels.getPtr(color).?;
        const idx: usize = @intCast(@reduce(.Add, start * BLOCK_STRIDE));
        light_levels.levels[idx] = 0;

        for (std.enums.values(Block.Direction)) |dir| {
            const chunk, const pos = self.get_chunk_block(start + dir.front_dir()) orelse continue;
            try queue.push(worker.temp(), .{ chunk, pos, 0 });
        }
    }

    outer: while (queue.pop()) |cur| {
        const chunk, const pos, _ = cur;
        if (chunk.get(pos).emitted_light_color() == color) continue;

        const light_levels = chunk.light_levels.getPtr(color) orelse continue;
        const idx: usize = @intCast(@reduce(.Add, pos * BLOCK_STRIDE));
        const cur_level = light_levels.levels[idx];
        if (cur_level == 0) continue;
        light_levels.levels[idx] = 0;

        for (std.enums.values(Block.Direction)) |dir| {
            const other = chunk.get_chunk_block(pos + dir.front_dir()) orelse continue;
            const other_chunk, const other_pos = other;
            const other_level = other_chunk.get_light_level(other_pos, color) orelse continue;

            if (other_level > cur_level) {
                std.debug.assert(other_level == cur_level + 1);
                light_levels.levels[idx] = cur_level;
                continue :outer;
            } else if (other_level == 0) continue;

            light_levels.levels[idx] = @max(light_levels.levels[idx], other_level - 1);

            try queue.push(worker.temp(), .{ other_chunk, other_pos, 0 });
        }

        try queue.push(worker.temp(), .{ chunk, pos, 0 });
    }
}

fn mesh_block(self: *Chunk, xyz: @Vector(3, usize), worker: *ChunkManager.Worker) !void {
    const pos: Coords = @intCast(xyz);
    const block = self.get(pos);
    if (block.is_air()) return;

    for (std.enums.values(Block.Direction)) |side| {
        const front = side.front_dir();
        if (self.is_solid_neighbour_face(pos + front, side.flip())) continue;

        const up = side.up_dir();
        const down = -side.up_dir();
        const left = side.left_dir();
        const right = -side.left_dir();

        const ao = [_]bool{
            self.casts_ao(pos + front + left),
            self.casts_ao(pos + front + right),
            self.casts_ao(pos + front + up),
            self.casts_ao(pos + front + down),
            self.casts_ao(pos + front + left + up),
            self.casts_ao(pos + front + right + up),
            self.casts_ao(pos + front + left + down),
            self.casts_ao(pos + front + right + down),
        };

        for (block.get_textures(side), block.get_faces(side)) |tex, face| {
            try self.faces.getPtr(side).append(worker.temp(), .init(
                pos,
                tex,
                face,
                ao,
            ));
        }
    }
}

fn is_solid_neighbour_face(self: *Chunk, pos: Coords, face: Block.Direction) bool {
    const chunk, const block = self.get_chunk_block(pos) orelse return false;
    return chunk.get(block).is_solid(face);
}

fn casts_ao(self: *Chunk, pos: Coords) bool {
    const chunk, const block = self.get_chunk_block(pos) orelse return false;
    return chunk.get(block).casts_ao();
}
