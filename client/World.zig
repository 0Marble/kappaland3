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

normal_gpa: std.mem.Allocator,
shared_gpa_base: Gpa = .init,
shared_gpa: std.heap.ThreadSafeAllocator = undefined,

load_radius: Coords = .{
    Options.world_size / 2,
    Options.world_height / 2,
    Options.world_size / 2,
},

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });

pub const Coords = @Vector(3, i32);

pub fn init(gpa: std.mem.Allocator) !*World {
    const self: *World = try gpa.create(World);
    logger.info("{*}: initializing", .{self});

    self.* = .{ .normal_gpa = gpa };
    self.shared_gpa = .{ .child_allocator = self.shared_gpa_base.allocator() };

    self.chunk_pool = .init(self.get_gpa());
    try self.renderer.init();
    self.chunk_manager = try ChunkManager.init(self, .{ .thread_count = 4 });

    try App.get_renderer().add_step(BlockRenderer.draw, .{&self.renderer});

    logger.info("{*}: initialized!", .{self});

    return self;
}

pub fn deinit(self: *World) void {
    logger.info("{*}: destroying", .{self});
    self.chunk_manager.deinit();

    for (self.chunks.values()) |chunk| {
        chunk.deinit(self.shared_gpa.allocator());
    }
    self.chunks.deinit(self.get_gpa());

    self.chunk_pool.deinit();
    self.renderer.deinit();
    std.debug.assert(self.shared_gpa_base.deinit() == .ok);
    self.get_gpa().destroy(self);
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

pub fn on_frame_start(self: *World) App.UnhandledError!void {
    try self.renderer.on_frame_start();
    try self.chunk_manager.on_frame_start();
}

pub fn world_to_chunk(w: Coords) Coords {
    return @divFloor(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn world_to_block(w: Coords) Coords {
    return @mod(w, @as(Coords, @splat(CHUNK_SIZE)));
}

pub fn get_gpa(self: *World) std.mem.Allocator {
    return self.normal_gpa;
}

pub fn to_world_coord(pos: zm.Vec3f) Coords {
    return @intFromFloat(@floor(pos));
}
