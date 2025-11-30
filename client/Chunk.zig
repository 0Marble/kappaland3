const World = @import("World.zig");
const std = @import("std");
const App = @import("App.zig");
const zm = @import("zm");
const Options = @import("ClientOptions");

const Stage = enum { dead, generating, meshing, active };

const CHUNK_SIZE = World.CHUNK_SIZE;
pub const X_OFFSET = 1;
pub const Z_OFFSET = CHUNK_SIZE;
pub const Y_OFFSET = CHUNK_SIZE * CHUNK_SIZE;

coords: World.ChunkCoords,
blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]World.BlockId,
stage: Stage,

const Chunk = @This();
pub fn create() !*Chunk {
    const self = try App.gpa().create(Chunk);
    self.coords = std.mem.zeroes(World.ChunkCoords);
    self.stage = .dead;
    return self;
}

pub fn init(self: *Chunk, coords: World.ChunkCoords) void {
    self.coords = coords;
    self.stage = .generating;
}

pub fn clear(self: *Chunk) void {
    self.stage = .dead;
}

pub fn process(self: *Chunk) !void {
    switch (self.stage) {
        .dead => return,
        .generating => {
            self.generate();
            self.stage = .meshing;
        },
        .meshing => {
            try App.renderer().upload_chunk(self);
            self.stage = .active;
        },
        .active => return,
    }
}

pub fn deinit(self: *Chunk) void {
    self.stage = .dead;
    App.gpa().destroy(self);
}

pub fn get(self: *Chunk, pos: World.BlockCoords) World.BlockId {
    return self.blocks[pos.x * X_OFFSET + pos.y * Y_OFFSET + pos.z * Z_OFFSET];
}

pub fn set(self: *Chunk, pos: World.BlockCoords, block: World.BlockId) void {
    self.blocks[pos.x * X_OFFSET + pos.y * Y_OFFSET + pos.z * Z_OFFSET] = block;
}

fn generate(self: *Chunk) void {
    const fptr = @field(Chunk, "generate_" ++ Options.world_gen);
    @call(.auto, fptr, .{self});
}

fn generate_grid(self: *Chunk) void {
    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            for (0..CHUNK_SIZE) |k| {
                const x: i32 = (self.coords.x * CHUNK_SIZE + @as(i32, @intCast(i)));
                const y: i32 = (self.coords.y * CHUNK_SIZE + @as(i32, @intCast(j)));
                const z: i32 = (self.coords.z * CHUNK_SIZE + @as(i32, @intCast(k)));
                const idx = i * X_OFFSET + j * Y_OFFSET + k * Z_OFFSET;

                if (@rem(x + y + z, 2) == 0) {
                    self.blocks[idx] = .air;
                } else {
                    self.blocks[idx] = .stone;
                }
            }
        }
    }
}

fn generate_flat(self: *Chunk) void {
    @memset(&self.blocks, .air);
    if (self.coords.y > 0) return;
    if (self.coords.y < 0) {
        @memset(&self.blocks, .stone);
        return;
    }

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |z| {
            for (0..4) |y| {
                self.set(.{ .x = x, .y = y, .z = z }, .stone);
            }
            for (4..8) |y| {
                self.set(.{ .x = x, .y = y, .z = z }, .dirt);
            }
            self.set(.{ .x = x, .y = 8, .z = z }, .grass);
            if (x == 0 or x + 1 == CHUNK_SIZE or z == 0 or z + 1 == CHUNK_SIZE) {
                self.set(.{ .x = x, .y = 8, .z = z }, .stone);
            }
        }
    }
}

fn generate_balls(self: *Chunk) void {
    const scale = std.math.pi / 8.0;
    for (0..CHUNK_SIZE) |i| {
        for (0..CHUNK_SIZE) |j| {
            for (0..CHUNK_SIZE) |k| {
                const x: f32 = @floatFromInt(self.coords.x * CHUNK_SIZE + @as(i32, @intCast(i)));
                const y: f32 = @floatFromInt(self.coords.y * CHUNK_SIZE + @as(i32, @intCast(j)));
                const z: f32 = @floatFromInt(self.coords.z * CHUNK_SIZE + @as(i32, @intCast(k)));
                const idx = i * X_OFFSET + j * Y_OFFSET + k * Z_OFFSET;
                const w = @abs(@sin(x * scale) + @cos(z * scale) + @sin(y * scale));
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
            const x: f32 = @floatFromInt(self.coords.x * CHUNK_SIZE + @as(i32, @intCast(i)));
            const z: f32 = @floatFromInt(self.coords.z * CHUNK_SIZE + @as(i32, @intCast(k)));
            const top: f32 = (@sin(x * scale) + @cos(z * scale)) * 4.0 + 8.0;

            for (0..CHUNK_SIZE) |j| {
                const y: f32 = @floatFromInt(self.coords.y * CHUNK_SIZE + @as(i32, @intCast(j)));
                if (y < top) {
                    self.set(.init(i, j, k), .stone);
                } else {
                    self.set(.init(i, j, k), .air);
                }
            }
        }
    }
}
