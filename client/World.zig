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

chunk_manager: *ChunkManager,
renderer: *BlockRenderer,
chunk_pool: std.heap.MemoryPool(Chunk),
chunks: std.AutoArrayHashMapUnmanaged(Coords, *Chunk),
gpa: Gpa,
temp: std.heap.ArenaAllocator,
load_radius: Coords = .{
    Options.world_size / 2,
    Options.world_height / 2,
    Options.world_size / 2,
},

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

pub const Coords = @Vector(3, i32);

pub fn get_block(self: *World, world_pos: Coords) Block {
    const block = world_to_block(world_pos);
    if (self.chunks.get(world_to_chunk(world_pos))) |chunk| return chunk.get(block);
    unreachable;
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

pub fn load_around(self: *World, world_pos: zm.Vec3f) !void {
    const chunk_coords = world_to_chunk(@intFromFloat(world_pos));
    try self.chunk_manager.schedule_load_region(chunk_coords, self.load_radius);
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
