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

const SAMPLES = 4;
const RENDERED_TEX_ATTACHMENT = 0;
const DEPTH_TEX_ATTACHMENT = 0;

block_renderer: BlockRenderer,

cur_width: i32,
cur_height: i32,

ms_fbo: gl.uint,
depth_tex: gl.uint,
rendered_tex: gl.uint,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.init_buffers();
    try self.block_renderer.init();
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
    gl.DeleteFramebuffers(1, @ptrCast(&self.ms_fbo));
    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex));
    gl.DeleteTextures(1, @ptrCast(&self.depth_tex));
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

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ms_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.rendered_tex));
    try gl_call(gl.TexImage2DMultisample(
        gl.TEXTURE_2D_MULTISAMPLE,
        SAMPLES,
        gl.RGBA16F,
        self.cur_width,
        self.cur_height,
        gl.TRUE,
    ));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
        gl.TEXTURE_2D_MULTISAMPLE,
        self.rendered_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.depth_tex));
    try gl_call(gl.TexImage2DMultisample(
        gl.TEXTURE_2D_MULTISAMPLE,
        SAMPLES,
        gl.DEPTH24_STENCIL8,
        self.cur_width,
        self.cur_height,
        gl.TRUE,
    ));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.DEPTH_STENCIL_ATTACHMENT + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D_MULTISAMPLE,
        self.depth_tex,
        0,
    ));

    const attachments: []const gl.@"enum" = &.{
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
    };
    try gl_call(gl.DrawBuffers(@intCast(attachments.len), attachments.ptr));

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'ms_fbo' incomplete!", .{self});
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, 0));
}

pub fn on_frame_start(self: *Renderer) !void {
    try self.block_renderer.on_frame_start();
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ms_fbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.depth_tex)));

    try self.resize_framebuffers(640, 480);
}
