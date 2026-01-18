const std = @import("std");
const Block = @import("../Block.zig");
const World = @import("../World.zig");
const Options = @import("Build").Options;
const BlockRenderer = @import("BlockRenderer.zig");
const ChunkManager = @import("ChunkManager.zig");
const Queue = @import("libmine").Queue;
const App = @import("../App.zig");
const LightList = @import("../Renderer.zig").LightList;
const LightLevelInfo = @import("../Renderer.zig").LightLevelInfo;

const Chunk = @This();
const Coords = World.Coords;
pub const CHUNK_SIZE = 16;

const X_STRIDE = 1;
const Y_STRIDE = CHUNK_SIZE * CHUNK_SIZE;
const Z_STRIDE = CHUNK_SIZE;
const BLOCK_STRIDE: @Vector(3, i32) = .{ X_STRIDE, Y_STRIDE, Z_STRIDE };
const SIZE: @Vector(3, i32) = @splat(CHUNK_SIZE);

world: *World,
coords: Coords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Block = undefined,
neighbours: std.enums.EnumMap(Block.Direction, *Chunk) = .init(.{}),
is_occluded: bool = false,
active: bool = false,
had_light_updates: bool = false,

light_sources: std.AutoArrayHashMapUnmanaged(Coords, void) = .empty,
light_levels: std.AutoArrayHashMapUnmanaged(LightColor, LightLevels) = .empty,
faces: std.EnumArray(Block.Direction, std.ArrayList(BlockRenderer.FaceMesh)) = .initFill(.empty),

compiled_light_lists: std.ArrayList(LightList) = .empty,
compiled_light_levels: std.ArrayList(LightLevelInfo) = .empty,

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
    self.compiled_light_levels.deinit(shared_gpa);
    self.compiled_light_lists.deinit(shared_gpa);
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
    for (&self.faces.values) |*faces| faces.clearRetainingCapacity();

    self.is_occluded &= self.next_layer_solid(.front, .{ 0, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.back, .{ CHUNK_SIZE - 1, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.right, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.left, .{ 0, 0, 0 });
    self.is_occluded &= self.next_layer_solid(.top, .{ 0, CHUNK_SIZE - 1, CHUNK_SIZE - 1 });
    self.is_occluded &= self.next_layer_solid(.bot, .{ CHUNK_SIZE - 1, 0, CHUNK_SIZE - 1 });
    if (self.is_occluded) return;

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                try self.mesh_block(.{ x, y, z }, worker);
            }
        }
    }
}

pub fn set_block_and_propagate_updates(
    self: *Chunk,
    pos: Coords,
    block: Block,
    worker: *ChunkManager.Worker,
) !void {
    std.debug.assert(worker.is_main_thread());
    const old_block = self.get(pos);
    if (old_block.idx == block.idx) return;
    self.set(pos, block);

    var queue = PropagateLightQueue.empty;
    defer queue.deinit(worker.temp());
    var updated_chunks = ChunksWithLightUpdates.empty;
    defer updated_chunks.deinit(worker.temp());
    try updated_chunks.ensureTotalCapacity(worker.temp(), 27);

    if (block.emits_light()) {
        try self.propagate_light_on_light_placed(
            pos,
            &queue,
            worker,
            &updated_chunks,
        );
    }

    for (self.light_levels.values()) |*light_levels| {
        if (block.emitted_light_color() == light_levels.color) continue;

        if (!block.is_air()) {
            try self.propagate_light_on_block_placed(
                pos,
                light_levels.color,
                &queue,
                worker,
                &updated_chunks,
            );
        } else if (old_block.emitted_light_color() == light_levels.color) {
            try self.propagate_light_on_light_broken(
                pos,
                light_levels.color,
                &queue,
                worker,
                &updated_chunks,
            );
        } else {
            try self.propagate_light_on_block_broken(
                pos,
                light_levels.color,
                &queue,
                worker,
                &updated_chunks,
            );
        }
    }

    for (updated_chunks.keys()) |chunk| {
        try chunk.compile_light_data(worker);
        // this is main thread so its ok
        try worker.parent.world.renderer.upload_chunk_lights(chunk);
    }
}

pub fn compile_light_data(self: *Chunk, worker: *ChunkManager.Worker) OOM!void {
    if (!self.had_light_updates) return;
    self.compiled_light_lists.clearRetainingCapacity();
    self.compiled_light_levels.clearRetainingCapacity();

    try self.compiled_light_lists.ensureTotalCapacity(
        worker.shared(),
        CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE,
    );
    self.compiled_light_lists.appendNTimesAssumeCapacity(
        0,
        CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE + 1,
    );
    self.compiled_light_lists.items[0] = 0;

    for (0..CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE) |i| {
        for (self.light_levels.values()) |*levels| {
            const info = levels.levels[i];
            if (info.level == 0) continue;
            try self.compiled_light_levels.append(worker.shared(), info);
        }
        const end = self.compiled_light_levels.items.len;
        self.compiled_light_lists.items[i + 1] = @intCast(end);
    }

    if (self.compiled_light_levels.items.len == 0) {
        self.compiled_light_lists.clearRetainingCapacity();
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

pub fn get_light_level(self: *Chunk, block: Coords, color: LightColor) u4 {
    const levels = self.light_levels.getPtr(color) orelse return 0;
    const idx: usize = @intCast(@reduce(.Add, block * BLOCK_STRIDE));
    return levels.levels[idx].level;
}

fn set_light_level(
    self: *Chunk,
    block: Coords,
    color: LightColor,
    level: u4,
    worker: *ChunkManager.Worker,
) OOM!void {
    const light_levels = blk: {
        const entry = try self.light_levels.getOrPut(worker.shared(), color);
        if (!entry.found_existing) entry.value_ptr.* = .init(color);
        break :blk entry.value_ptr;
    };
    const idx: usize = @intCast(@reduce(.Add, block * BLOCK_STRIDE));
    light_levels.levels[idx].level = level;
    self.had_light_updates = true;
}

pub fn to_world_coords(self: *Chunk, pos: Coords) Coords {
    return self.coords * SIZE + pos;
}

const LightColor = u12;
const LightLevels = struct {
    color: LightColor,
    levels: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]LightLevelInfo,

    fn init(color: LightColor) LightLevels {
        return LightLevels{
            .color = color,
            .levels = @splat(.{ .color = color }),
        };
    }
};

fn propagate_light_on_light_placed(
    self: *Chunk,
    start: Coords,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
    updated_chunks: *ChunksWithLightUpdates,
) OOM!void {
    const color = self.get(start).emitted_light_color().?;
    const level = self.get(start).emitted_light_level().?;
    try self.set_light_level(start, color, level, worker);
    updated_chunks.putAssumeCapacity(self, {});
    if (level == 1) return;
    try self.propagate_light(start, color, queue, worker, updated_chunks);
}

fn propagate_light_on_block_broken(
    self: *Chunk,
    start: Coords,
    color: LightColor,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
    updated_chunks: *ChunksWithLightUpdates,
) OOM!void {
    const orig_level = self.get_light_level(start, color);
    var this_level = orig_level;
    for (std.enums.values(Block.Direction)) |dir| {
        const chunk, const pos = self.get_chunk_block(start + dir.front_dir()) orelse continue;
        const level = chunk.get_light_level(pos, color);
        if (level <= 1) continue;
        this_level = @max(this_level, level - 1);
    }

    if (this_level == orig_level) return;
    try self.set_light_level(start, color, this_level, worker);
    updated_chunks.putAssumeCapacity(self, {});
    try self.propagate_light(start, color, queue, worker, updated_chunks);
}

fn propagate_light_on_block_placed(
    self: *Chunk,
    start: Coords,
    color: LightColor,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
    updated_chunks: *ChunksWithLightUpdates,
) OOM!void {
    var visited = std.AutoHashMapUnmanaged(Coords, void).empty;
    var frontier = std.AutoArrayHashMapUnmanaged(struct { *Chunk, Coords }, void).empty;
    defer visited.deinit(worker.temp());
    defer frontier.deinit(worker.temp());

    const start_level = self.get_light_level(start, color);
    if (start_level == 0) return;

    try queue.push(worker.temp(), .{ self, start });
    while (queue.pop()) |cur| {
        const chunk, const pos = cur;
        const level = chunk.get_light_level(pos, color);

        for (std.enums.values(Block.Direction)) |dir| {
            const next = chunk.get_chunk_block(pos + dir.front_dir()) orelse continue;
            const next_chunk, const next_pos = next;
            const next_level = next_chunk.get_light_level(next_pos, color);
            if (next_level == 0) continue;

            const entry = try visited.getOrPut(
                worker.temp(),
                next_chunk.to_world_coords(next_pos),
            );
            if (entry.found_existing) continue;

            if (next_level < level) {
                try queue.push(worker.temp(), .{ next_chunk, next_pos });
            } else {
                try frontier.put(worker.temp(), .{ next_chunk, next_pos }, {});
            }
        }

        try chunk.set_light_level(pos, color, 0, worker);
        updated_chunks.putAssumeCapacity(chunk, {});
    }

    for (frontier.keys()) |cur| {
        const chunk, const pos = cur;
        try chunk.propagate_light(pos, color, queue, worker, updated_chunks);
    }
}

fn propagate_light_on_light_broken(
    self: *Chunk,
    start: Coords,
    color: LightColor,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
    updated_chunks: *ChunksWithLightUpdates,
) OOM!void {
    try self.propagate_light_on_block_placed(start, color, queue, worker, updated_chunks);
}

const PropagateLightQueue = Queue(struct { *Chunk, Coords });
const ChunksWithLightUpdates = std.AutoArrayHashMapUnmanaged(*Chunk, void);
fn propagate_light(
    self: *Chunk,
    start: Coords,
    color: LightColor,
    queue: *PropagateLightQueue,
    worker: *ChunkManager.Worker,
    updated_chunks: *ChunksWithLightUpdates,
) OOM!void {
    std.debug.assert(worker.is_main_thread());
    if (self.get_light_level(start, color) <= 1) return;

    try queue.push(worker.temp(), .{ self, start });

    while (queue.pop()) |cur| {
        const chunk, const pos = cur;
        const level = chunk.get_light_level(pos, color);
        std.debug.assert(level > 1);

        for (std.enums.values(Block.Direction)) |d| {
            const next = chunk.get_chunk_block(d.front_dir() + pos) orelse continue;
            const next_chunk, const next_pos = next;
            if (!next_chunk.get(next_pos).is_air()) continue;
            if (next_chunk.get_light_level(next_pos, color) >= level - 1) continue;

            try next_chunk.set_light_level(next_pos, color, level - 1, worker);
            updated_chunks.putAssumeCapacity(next_chunk, {});

            if (level - 1 > 1) {
                try queue.push(worker.temp(), .{ next_chunk, next_pos });
            }
        }
    }
}

fn mesh_block(self: *Chunk, xyz: @Vector(3, usize), worker: *ChunkManager.Worker) !void {
    const pos: Coords = @intCast(xyz);
    const block = self.get(pos);
    if (block.is_air()) return;
    const light_names = comptime blk: {
        var res = std.mem.zeroes([16][]const u8);
        for (0..std.math.maxInt(u4) + 1) |lvl| {
            res[lvl] = std.fmt.comptimePrint(".blocks.main.debug.light_level_{d}", .{lvl});
        }
        break :blk res;
    };

    for (std.enums.values(Block.Direction)) |side| {
        const front = side.front_dir();
        if (self.is_solid_neighbour_face(pos + front, side.flip())) continue;

        var light_lvl_tex: usize = 0;
        if (Options.light_debug) {
            if (self.get_chunk_block(pos + side.front_dir())) |next| {
                const next_chunk, const next_pos = next;
                const tex_name = light_names[next_chunk.get_light_level(next_pos, 0xF0F)];
                light_lvl_tex = App.assets().get_blocks_atlas().get_idx_or_warn(tex_name);
            }
        }

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
            if (Options.light_debug) {
                try self.faces.getPtr(side).append(worker.temp(), .init(
                    pos,
                    light_lvl_tex,
                    face,
                    ao,
                ));
            } else {
                try self.faces.getPtr(side).append(worker.shared(), .init(pos, tex, face, ao));
            }
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

            if (!self.is_solid_neighbour_face(pos + front, normal.flip())) return false;
        }
    }

    return true;
}
