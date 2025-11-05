pub const BlockRenderer = @import("BlockRenderer.zig");
const App = @import("App.zig");
const gl = @import("gl");
const std = @import("std");
const Chunk = @import("Chunk.zig");
const World = @import("World.zig");
const util = @import("util.zig");
const gl_call = util.gl_call;
const Log = @import("libmine").Log;
const Mesh = @import("Mesh.zig");
const Shader = @import("Shader.zig");
const zm = @import("zm");
const Options = @import("ClientOptions");

block_renderer: BlockRenderer,

cur_width: i32,
cur_height: i32,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    self.cur_width = 640;
    self.cur_height = 480;
    try self.block_renderer.init();
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
}

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    try gl_call(gl.ClearDepth(0.0));
    try gl_call(gl.ClearColor(0, 0, 0, 1));

    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    try self.block_renderer.draw();

    try App.gui().draw();
}

pub fn resize_framebuffers(self: *Renderer, w: i32, h: i32) !void {
    if (self.cur_width == w and self.cur_height == h) return;
    self.cur_width = w;
    self.cur_height = h;
}
