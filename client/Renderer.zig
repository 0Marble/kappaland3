const BlockRenderer = @import("BlockRenderer.zig");
const App = @import("App.zig");
const gl = @import("gl");
const std = @import("std");
const Chunk = @import("Chunk.zig");
const World = @import("World.zig");

block_renderer: BlockRenderer,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.block_renderer.init();
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
}

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    try self.block_renderer.draw();
}
