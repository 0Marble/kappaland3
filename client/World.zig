const std = @import("std");
const App = @import("App.zig");
const Block = @import("Block.zig");
const ChunkManager = @import("world/ChunkManager.zig");
const BlockRenderer = @import("world/BlockRenderer.zig");
const Options = @import("Build").Options;
const Chunk = @import("world/Chunk.zig");
const World = @This();
const logger = std.log.scoped(.world);
const zm = @import("zm");
pub const CHUNK_SIZE = Chunk.CHUNK_SIZE;

chunk_manager: *ChunkManager = undefined,
renderer: BlockRenderer = undefined,
chunk_pool: std.heap.MemoryPool(Chunk) = undefined,
chunks: std.AutoArrayHashMapUnmanaged(Coords, *Chunk) = .empty,
gpa: Gpa,
load_radius: Coords = .{
    Options.world_size / 2,
    Options.world_height / 2,
    Options.world_size / 2,
},

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

pub const Coords = @Vector(3, i32);

pub fn init() !*World {
    var gpa = Gpa.init;
    const self = try gpa.allocator().create(World);
    self.* = .{ .gpa = gpa };
    self.chunk_pool = .init(self.get_gpa());
    try self.renderer.init();
    self.chunk_manager = try ChunkManager.init(self, .{ .thread_count = 4 });
    return self;
}

pub fn deinit(self: *World) void {
    self.chunk_pool.deinit();
    self.renderer.deinit();
    self.chunk_manager.deinit();
    var gpa = self.gpa;
    gpa.allocator().destroy(self);
}

pub fn get_block(self: *World, world_pos: Coords) Block {
    const block = world_to_block(world_pos);
    const chunk = self.chunks.get(world_to_chunk(world_pos)).?;
    return chunk.get(block);
}

pub fn get_block_safe(self: *World, world_pos: Coords) ?Block {
    const block = world_to_block(world_pos);
    if (self.chunks.get(world_to_chunk(world_pos))) |chunk| return chunk.get(block);
    return null;
}

pub fn set_block(self: *World, world_pos: Coords, block: Block) !void {
    const chunk_coords = world_to_chunk(world_pos);
    const block_coords = world_to_block(world_pos);
    const chunk = self.chunks.get(chunk_coords) orelse {
        logger.warn("{*} attempted to set block at inactive chunk {}", .{ self, chunk_coords });
        return;
    };
    try self.chunk_manager.schedule_set_block(chunk, block_coords, block);
}

pub fn load_around(self: *World, chunk: Coords) !void {
    try self.chunk_manager.schedule_load_region(chunk, self.load_radius);
}

pub fn update(self: *World) App.UnhandledError!void {
    try self.chunk_manager.process();
}

pub fn world_to_chunk(w: Coords) Coords {
    return @divFloor(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: Coords) Coords {
    return @mod(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn get_gpa(self: *World) std.mem.Allocator {
    return self.gpa.allocator();
}

pub fn to_world_coord(pos: zm.Vec3f) Coords {
    return @intFromFloat(@floor(pos));
}
