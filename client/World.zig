const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const std = @import("std");

const CHUNK_SIZE = 16;

pub const Block = struct {};

pub const Chunk = struct {
    blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]Ecs.EntityRef,
};
