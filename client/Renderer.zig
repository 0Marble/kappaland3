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
const RENDERED_TEX_UNIFORM = 0;
const DEPTH_TEX_UNIFORM = 1;

block_renderer: BlockRenderer,

cur_width: i32,
cur_height: i32,

ms_fbo: gl.uint,
depth_tex_ms: gl.uint,
rendered_tex_ms: gl.uint,
copy_fbo: gl.uint,
rendered_tex: gl.uint,
depth_tex: gl.uint,

screen_quad: Mesh,
postprocessing: Shader,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.init_buffers();
    try self.block_renderer.init();
    try self.init_screen();
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
    gl.DeleteFramebuffers(1, @ptrCast(&self.ms_fbo));
    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex_ms));
    gl.DeleteTextures(1, @ptrCast(&self.depth_tex_ms));
    gl.DeleteFramebuffers(1, @ptrCast(&self.postprocessing));
    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex));
    gl.DeleteTextures(1, @ptrCast(&self.depth_tex));

    self.screen_quad.deinit();
    self.postprocessing.deinit();
}

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    try gl_call(gl.ClearDepth(0.0));
    try gl_call(gl.ClearColor(0, 0, 0, 1));
    try gl_call(gl.Enable(gl.DEPTH_TEST));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ms_fbo));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    try self.block_renderer.draw();

    try gl_call(gl.BindFramebuffer(gl.READ_FRAMEBUFFER, self.ms_fbo));
    try gl_call(gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, self.copy_fbo));
    try gl_call(gl.BlitFramebuffer(
        0,
        0,
        self.cur_width,
        self.cur_height,
        0,
        0,
        self.cur_width,
        self.cur_height,
        gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT,
        gl.NEAREST,
    ));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.postprocessing.bind();
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + RENDERED_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + DEPTH_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try self.screen_quad.draw(gl.TRIANGLES);
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));

    try App.gui().draw();
}

pub fn resize_framebuffers(self: *Renderer, w: i32, h: i32) !void {
    if (self.cur_width == w and self.cur_height == h) return;
    self.cur_width = w;
    self.cur_height = h;

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ms_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.rendered_tex_ms));
    try gl_call(gl.TexImage2DMultisample(
        gl.TEXTURE_2D_MULTISAMPLE,
        SAMPLES,
        gl.RGBA16F,
        w,
        h,
        gl.TRUE,
    ));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
        gl.TEXTURE_2D_MULTISAMPLE,
        self.rendered_tex_ms,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, self.depth_tex_ms));
    try gl_call(gl.TexImage2DMultisample(
        gl.TEXTURE_2D_MULTISAMPLE,
        SAMPLES,
        gl.DEPTH24_STENCIL8,
        w,
        h,
        gl.TRUE,
    ));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.DEPTH_STENCIL_ATTACHMENT + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D_MULTISAMPLE,
        self.depth_tex_ms,
        0,
    ));

    // const attachments_ms: []const gl.@"enum" = &.{
    //     gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
    // };
    // try gl_call(gl.DrawBuffers(@intCast(attachments_ms.len), attachments_ms.ptr));

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'ms_fbo' incomplete!", .{self});
    }
    try gl_call(gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, 0));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.copy_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.rendered_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try gl_call(gl.TexImage2D(
        gl.TEXTURE_2D,
        0,
        gl.DEPTH24_STENCIL8,
        w,
        h,
        0,
        gl.DEPTH_STENCIL,
        gl.UNSIGNED_INT_24_8,
        null,
    ));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.DEPTH_STENCIL_ATTACHMENT + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.depth_tex,
        0,
    ));

    // const attachments_copy: []const gl.@"enum" = &.{
    //     gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
    // };
    // try gl_call(gl.DrawBuffers(@intCast(attachments_copy.len), attachments_copy.ptr));

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'copy_fbo' incomplete!", .{self});
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
}

pub fn on_frame_start(self: *Renderer) !void {
    try self.block_renderer.on_frame_start();
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ms_fbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex_ms)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.depth_tex_ms)));

    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.copy_fbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.depth_tex)));

    try self.resize_framebuffers(640, 480);
}

fn init_screen(self: *Renderer) !void {
    self.screen_quad = try Mesh.init(QuadVert, u8, &.{
        .{ .pos = .{ .x = -1, .y = -1 }, .uv = .{ .u = 0, .v = 0 } },
        .{ .pos = .{ .x = -1, .y = 1 }, .uv = .{ .u = 0, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = 1 }, .uv = .{ .u = 1, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = -1 }, .uv = .{ .u = 1, .v = 0 } },
    }, &.{ 0, 1, 2, 0, 2, 3 }, gl.STATIC_DRAW);

    var sources: [2]Shader.Source = .{
        .{ .name = "post_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "post_frag", .sources = &.{frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.postprocessing = try .init(&sources);
    try self.postprocessing.set_int("u_rendered_tex", RENDERED_TEX_UNIFORM);
    try self.postprocessing.set_int("u_depth_tex", DEPTH_TEX_UNIFORM);
}

const QuadVert = struct {
    pos: struct { x: f32, y: f32 },
    uv: struct { u: f32, v: f32 },

    pub fn setup_attribs() !void {
        inline for (.{ "pos", "uv" }, 0..) |name, i| {
            try gl_call(gl.VertexAttribPointer(
                i,
                @intCast(std.meta.fields(@FieldType(@This(), name)).len),
                gl.FLOAT,
                gl.FALSE,
                @sizeOf(@This()),
                @offsetOf(@This(), name),
            ));
            try gl_call(gl.EnableVertexAttribArray(i));
        }
    }
};

const vert =
    \\#version 460 core
    \\layout (location = 0) in vec2 vert_pos;
    \\layout (location = 1) in vec2 vert_uv;
    \\out vec2 frag_uv;
    \\void main() { gl_Position = vec4(vert_pos, 0, 1); frag_uv = vert_uv; }
;
const frag =
    \\#version 460 core
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\uniform sampler2D u_rendered_tex;
    \\uniform sampler2D u_depth_tex;
    \\void main() { out_color = texture(u_rendered_tex, frag_uv); }
;
