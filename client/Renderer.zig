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

const SAMPLES_COUNT = 64;

pub const POSITION_TEX_ATTACHMENT = 0;
pub const NORMAL_TEX_ATTACHMENT = 1;
pub const BASE_TEX_ATTACHMENT = 2;
const DEPTH_TEX_ATTACHMENT = 0;
const RENDERED_TEX_ATTACHMENT = 0;

const POSITION_TEX_UNIFORM = 0;
const NORMAL_TEX_UNIFORM = 1;
const BASE_TEX_UNIFORM = 2;
const DEPTH_TEX_UNIFORM = 3;
const RENDERED_TEX_UNIFORM = 4;

block_renderer: BlockRenderer,

cur_width: i32,
cur_height: i32,

g_buffer_fbo: gl.uint,
depth_tex: gl.uint,
position_tex: gl.uint,
normal_tex: gl.uint,
base_tex: gl.uint,
render_fbo: gl.uint,
rendered_tex: gl.uint,

screen_quad: Mesh,
postprocessing: Shader,
rendering: Shader,
ssao_samples: [SAMPLES_COUNT]zm.Vec3f,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.init_buffers();
    try self.block_renderer.init();
    try self.init_screen();
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
    gl.DeleteFramebuffers(1, @ptrCast(&self.g_buffer_fbo));
    gl.DeleteFramebuffers(1, @ptrCast(&self.render_fbo));
    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex));
    gl.DeleteTextures(1, @ptrCast(&self.depth_tex));
    gl.DeleteTextures(1, @ptrCast(&self.position_tex));
    gl.DeleteTextures(1, @ptrCast(&self.normal_tex));
    gl.DeleteTextures(1, @ptrCast(&self.base_tex));

    self.screen_quad.deinit();
    self.postprocessing.deinit();
    self.rendering.deinit();
}

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    try gl_call(gl.ClearDepth(0.0));
    try gl_call(gl.ClearColor(0, 0, 0, 1));
    try gl_call(gl.Enable(gl.DEPTH_TEST));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.g_buffer_fbo));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    try self.block_renderer.draw();

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.render_fbo));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.rendering.bind();
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + POSITION_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NORMAL_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + BASE_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + DEPTH_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try self.rendering.set_vec3("u_view_pos", App.game_state().camera.pos);
    try self.screen_quad.draw(gl.TRIANGLES);
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
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

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.g_buffer_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + POSITION_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.position_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + NORMAL_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.normal_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + BASE_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.base_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT32, w, h, 0, gl.DEPTH_COMPONENT, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.DEPTH_ATTACHMENT + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.depth_tex,
        0,
    ));

    const draw_buffers: []const gl.uint = &.{
        gl.COLOR_ATTACHMENT0 + POSITION_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + NORMAL_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + BASE_TEX_ATTACHMENT,
    };
    try gl_call(gl.DrawBuffers(@intCast(draw_buffers.len), @ptrCast(draw_buffers)));
    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'g_buffer' incomplete!", .{self});
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.render_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.rendered_tex,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.DEPTH_ATTACHMENT + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.depth_tex,
        0,
    ));

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'render_fbo' incomplete!", .{self});
    }
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
}

pub fn on_frame_start(self: *Renderer) !void {
    try self.block_renderer.on_frame_start();
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.g_buffer_fbo)));
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.render_fbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.depth_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.position_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.normal_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.base_tex)));

    try self.resize_framebuffers(640, 480);
}

fn init_screen(self: *Renderer) !void {
    self.screen_quad = try Mesh.init(QuadVert, u8, &.{
        .{ .pos = .{ .x = -1, .y = -1 }, .uv = .{ .u = 0, .v = 0 } },
        .{ .pos = .{ .x = -1, .y = 1 }, .uv = .{ .u = 0, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = 1 }, .uv = .{ .u = 1, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = -1 }, .uv = .{ .u = 1, .v = 0 } },
    }, &.{ 0, 1, 2, 0, 2, 3 }, gl.STATIC_DRAW);

    for (0..SAMPLES_COUNT) |i| {
        self.ssao_samples[i] = .{
            App.rng().float(f32) * 2 - 1,
            App.rng().float(f32) * 2 - 1,
            App.rng().float(f32) * 2 - 1,
        };
    }

    var render_sources: [2]Shader.Source = .{
        .{ .name = "render_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "render_frag", .sources = &.{rendering_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.rendering = try .init(&render_sources);
    try self.rendering.set_vec3("u_ambient", .{ 0.1, 0.1, 0.1 });
    try self.rendering.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 2, 1, 1 }));
    try self.rendering.set_vec3("u_light_color", .{ 1, 1, 0.9 });
    try self.rendering.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.rendering.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.rendering.set_int("u_base_tex", BASE_TEX_UNIFORM);

    var post_sources: [2]Shader.Source = .{
        .{ .name = "post_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "post_frag", .sources = &.{postprocessing_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.postprocessing = try .init(&post_sources);
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
const postprocessing_frag =
    \\#version 460 core
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\
    \\uniform sampler2D u_rendered_tex;
    \\uniform sampler2D u_depth_tex;
    \\
    \\void main() {
    \\  out_color = texture(u_rendered_tex, frag_uv);
    \\}
;
const rendering_frag =
    \\#version 460 core
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\
    \\uniform sampler2D u_pos_tex;
    \\uniform sampler2D u_normal_tex;
    \\uniform sampler2D u_base_tex;
    \\
    \\uniform vec3 u_ambient;
    \\uniform vec3 u_light_color;
    \\uniform vec3 u_light_dir;
    \\uniform vec3 u_view_pos;
    \\
    \\void main() {
    \\  vec3 frag_color = texture(u_base_tex, frag_uv).rgb;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  vec3 ambient = u_ambient * frag_color;
    \\
    \\  vec3 norm = normalize(frag_norm);
    \\  vec3 light_dir = u_light_dir;
    \\  float diff = max(dot(norm, light_dir), 0.0);
    \\  vec3 diffuse = u_light_color * diff * frag_color;
    \\
    \\  out_color = vec4(ambient + diffuse, 1);
    \\}
;
