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
const c = @import("c.zig").c;

const SSAO_SAMPLES_COUNT = 16;
const NOISE_SIZE = 16;

pub const POSITION_TEX_ATTACHMENT = 0;
pub const NORMAL_TEX_ATTACHMENT = 1;
pub const BASE_TEX_ATTACHMENT = 2;
pub const DEPTH_TEX_ATTACHMENT = 3;
pub const SSAO_TEX_ATTACHMENT = 0;
const RENDERED_TEX_ATTACHMENT = 0;

const POSITION_TEX_UNIFORM = 0;
const NORMAL_TEX_UNIFORM = 1;
const BASE_TEX_UNIFORM = 2;
const SSAO_TEX_UNIFORM = 3;
const DEPTH_TEX_UNIFORM = 4;
const RENDERED_TEX_UNIFORM = 5;
const NOISE_TEX_UNIFORM = 6;

block_renderer: BlockRenderer,

cur_width: i32,
cur_height: i32,

g_buffer_fbo: gl.uint,
depth_tex: gl.uint,
depth_rbo: gl.uint,
position_tex: gl.uint,
normal_tex: gl.uint,
base_tex: gl.uint,
ssao_fbo: gl.uint,
ssao_tex: gl.uint,
ssao_blur_tex: gl.uint,
ssao_blur_fbo: gl.uint,
render_fbo: gl.uint,
rendered_tex: gl.uint,
noise_tex: gl.uint,

screen_quad: Mesh,
postprocessing_pass: Shader,
ssao_pass: Shader,
ssao_blur_pass: Shader,
lighting_pass: Shader,
ssao_samples: [SSAO_SAMPLES_COUNT]zm.Vec3f,

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
    if (Options.enable_ssao) {
        gl.DeleteFramebuffers(1, @ptrCast(&self.ssao_fbo));
        gl.DeleteFramebuffers(1, @ptrCast(&self.ssao_blur_fbo));
    }

    gl.DeleteRenderbuffers(1, @ptrCast(&self.depth_rbo));

    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex));
    gl.DeleteTextures(1, @ptrCast(&self.depth_tex));
    gl.DeleteTextures(1, @ptrCast(&self.position_tex));
    gl.DeleteTextures(1, @ptrCast(&self.normal_tex));
    gl.DeleteTextures(1, @ptrCast(&self.base_tex));

    if (Options.enable_ssao) {
        gl.DeleteTextures(1, @ptrCast(&self.ssao_tex));
        gl.DeleteTextures(1, @ptrCast(&self.ssao_blur_tex));
        gl.DeleteTextures(1, @ptrCast(&self.noise_tex));
    }

    self.screen_quad.deinit();
    self.postprocessing_pass.deinit();
    self.lighting_pass.deinit();
    if (Options.enable_ssao) {
        self.ssao_pass.deinit();
        self.ssao_blur_pass.deinit();
    }
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

    if (Options.enable_ssao) {
        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_fbo));
        try gl_call(gl.Disable(gl.DEPTH_TEST));
        try self.ssao_pass.bind();
        try self.ssao_pass.set_mat4("u_vp", App.game_state().camera.vp_mat());
        try self.ssao_pass.set_vec2("u_noise_scale", .{
            @as(f32, @floatFromInt(self.cur_width)) / NOISE_SIZE,
            @as(f32, @floatFromInt(self.cur_height)) / NOISE_SIZE,
        });
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + POSITION_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NORMAL_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_tex));
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NOISE_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.noise_tex));
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + DEPTH_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
        try self.screen_quad.draw(gl.TRIANGLES);

        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_blur_fbo));
        try gl_call(gl.Disable(gl.DEPTH_TEST));
        try self.ssao_blur_pass.bind();
        try self.ssao_blur_pass.set_vec2("u_tex_size", .{ @floatFromInt(self.cur_width), @floatFromInt(self.cur_height) });
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + SSAO_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_tex));
        try self.screen_quad.draw(gl.TRIANGLES);
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.render_fbo));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.lighting_pass.bind();
    try self.lighting_pass.set_vec3("u_view_pos", App.game_state().camera.pos);
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + POSITION_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NORMAL_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + BASE_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_tex));
    if (Options.enable_ssao) {
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + SSAO_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_blur_tex));
    }
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + DEPTH_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.depth_tex));
    try self.screen_quad.draw(gl.TRIANGLES);
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.postprocessing_pass.bind();
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + RENDERED_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
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
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R16F, w, h, 0, gl.RED, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + DEPTH_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.depth_tex,
        0,
    ));

    try gl_call(gl.BindRenderbuffer(gl.RENDERBUFFER, self.depth_rbo));
    try gl_call(gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT, w, h));
    try gl_call(gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, self.depth_rbo));

    const g_buffer_draw_buffers: []const gl.uint = &.{
        gl.COLOR_ATTACHMENT0 + POSITION_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + NORMAL_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + BASE_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + DEPTH_TEX_ATTACHMENT,
    };
    try gl_call(gl.DrawBuffers(@intCast(g_buffer_draw_buffers.len), @ptrCast(g_buffer_draw_buffers)));
    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'g_buffer' incomplete!", .{self});
    }

    if (Options.enable_ssao) {
        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_fbo));

        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_tex));
        try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R16, w, h, 0, gl.RED, gl.FLOAT, null));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
        try gl_call(gl.FramebufferTexture2D(
            gl.FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0 + SSAO_TEX_ATTACHMENT,
            gl.TEXTURE_2D,
            self.ssao_tex,
            0,
        ));

        const ssao_draw_buffers: []const gl.uint = &.{
            gl.COLOR_ATTACHMENT0 + SSAO_TEX_ATTACHMENT,
        };
        try gl_call(gl.DrawBuffers(@intCast(ssao_draw_buffers.len), @ptrCast(ssao_draw_buffers)));
        if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
            Log.log(.warn, "{*}: framebuffer 'ssao_fbo' incomplete!", .{self});
        }

        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_blur_fbo));

        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_blur_tex));
        try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R16, w, h, 0, gl.RED, gl.FLOAT, null));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
        try gl_call(gl.FramebufferTexture2D(
            gl.FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0 + SSAO_TEX_ATTACHMENT,
            gl.TEXTURE_2D,
            self.ssao_blur_tex,
            0,
        ));

        const ssao_blur_draw_buffers: []const gl.uint = &.{
            gl.COLOR_ATTACHMENT0 + SSAO_TEX_ATTACHMENT,
        };
        try gl_call(gl.DrawBuffers(@intCast(ssao_blur_draw_buffers.len), @ptrCast(ssao_blur_draw_buffers)));
        if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
            Log.log(.warn, "{*}: framebuffer 'ssao_blur_fbo' incomplete!", .{self});
        }
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

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        Log.log(.warn, "{*}: framebuffer 'render_fbo' incomplete!", .{self});
    }
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
}

pub fn on_frame_start(self: *Renderer) !void {
    try self.block_renderer.on_frame_start();

    try App.gui().add_to_frame(Renderer, "FBO", self, draw_fbo_debug, @src());
}

fn draw_fbo_debug(self: *Renderer) !void {
    const uv_min: c.ImVec2 = .{ .x = 0, .y = 1 };
    const uv_max: c.ImVec2 = .{ .x = 1, .y = 0 };
    const scale = 0.1;
    const size: c.ImVec2 = .{
        .x = @as(f32, @floatFromInt(self.cur_width)) * scale,
        .y = @as(f32, @floatFromInt(self.cur_height)) * scale,
    };

    const textures: []const [:0]const u8 = &(.{ "position_tex", "normal_tex", "base_tex", "depth_tex" } ++ if (Options.enable_ssao)
        .{ "ssao_tex", "ssao_blur_tex" }
    else
        .{});

    inline for (textures) |name| {
        c.igText(name);
        const tex: c.ImTextureRef = .{ ._TexID = @intCast(@field(self, name)) };
        c.igImage(tex, size, uv_min, uv_max);
    }
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.g_buffer_fbo)));
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.render_fbo)));
    if (Options.enable_ssao) {
        try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ssao_fbo)));
        try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ssao_blur_fbo)));
    }

    try gl_call(gl.GenRenderbuffers(1, @ptrCast(&self.depth_rbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.depth_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.position_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.normal_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.base_tex)));

    if (Options.enable_ssao) {
        try gl_call(gl.GenTextures(1, @ptrCast(&self.ssao_tex)));
        try gl_call(gl.GenTextures(1, @ptrCast(&self.ssao_blur_tex)));
        try gl_call(gl.GenTextures(1, @ptrCast(&self.noise_tex)));
    }

    if (Options.enable_ssao) {
        var noise = std.mem.zeroes([NOISE_SIZE * NOISE_SIZE * 4]f32);
        for (0..NOISE_SIZE * NOISE_SIZE) |i| {
            noise[4 * i + 0] = App.rng().float(f32) * 2 - 1;
            noise[4 * i + 1] = App.rng().float(f32) * 2 - 1;
            noise[4 * i + 2] = App.rng().float(f32) * 2 - 1;
            noise[4 * i + 3] = 1;
        }

        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.noise_tex));
        try gl_call(gl.TexImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA16F,
            NOISE_SIZE,
            NOISE_SIZE,
            0,
            gl.RGBA,
            gl.FLOAT,
            @ptrCast(&noise),
        ));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT));
        try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT));
    }

    try self.resize_framebuffers(640, 480);
}

fn init_screen(self: *Renderer) !void {
    self.screen_quad = try Mesh.init(QuadVert, u8, &.{
        .{ .pos = .{ .x = -1, .y = -1 }, .uv = .{ .u = 0, .v = 0 } },
        .{ .pos = .{ .x = -1, .y = 1 }, .uv = .{ .u = 0, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = 1 }, .uv = .{ .u = 1, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = -1 }, .uv = .{ .u = 1, .v = 0 } },
    }, &.{ 0, 1, 2, 0, 2, 3 }, gl.STATIC_DRAW);

    var render_sources: [2]Shader.Source = .{
        .{ .name = "render_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "render_frag", .sources = &.{lighting_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.lighting_pass = try .init(&render_sources);
    try self.lighting_pass.set_vec3("u_ambient", .{ 0.3, 0.3, 0.3 });
    try self.lighting_pass.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 1, 1, 1 }));
    try self.lighting_pass.set_vec3("u_light_color", .{ 1, 1, 0.9 });
    try self.lighting_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_base_tex", BASE_TEX_UNIFORM);
    if (Options.enable_ssao) {
        try self.lighting_pass.set_int("u_ssao_tex", SSAO_TEX_UNIFORM);
    }

    var post_sources: [2]Shader.Source = .{
        .{ .name = "post_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "post_frag", .sources = &.{postprocessing_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.postprocessing_pass = try .init(&post_sources);
    try self.postprocessing_pass.set_int("u_rendered_tex", RENDERED_TEX_UNIFORM);
    try self.postprocessing_pass.set_int("u_depth_tex", DEPTH_TEX_UNIFORM);

    if (Options.enable_ssao) {
        var ssao_sources: [2]Shader.Source = .{
            .{ .name = "ssao_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
            .{ .name = "ssao_frag", .sources = &.{ssao_frag}, .kind = gl.FRAGMENT_SHADER },
        };
        self.ssao_pass = try .init(&ssao_sources);
        try self.ssao_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
        try self.ssao_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
        try self.ssao_pass.set_int("u_noise_tex", NOISE_TEX_UNIFORM);
        try self.ssao_pass.set_int("u_depth_tex", DEPTH_TEX_UNIFORM);

        var ssao_blur_sources: [2]Shader.Source = .{
            .{ .name = "ssao_blur_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
            .{ .name = "ssao_blur_frag", .sources = &.{blur_frag}, .kind = gl.FRAGMENT_SHADER },
        };
        self.ssao_blur_pass = try .init(&ssao_blur_sources);
        try self.ssao_blur_pass.set_int("u_tex", SSAO_TEX_UNIFORM);

        for (0..SSAO_SAMPLES_COUNT) |i| {
            self.ssao_samples[i] = zm.vec.normalize(zm.Vec3f{
                App.rng().float(f32) * 2 - 1,
                App.rng().float(f32) * 2 - 1,
                App.rng().float(f32),
            });
            self.ssao_samples[i] *= @splat(App.rng().float(f32));
            const name = try std.fmt.allocPrintSentinel(App.frame_alloc(), "u_ssao_samples[{d}]", .{i}, 0);
            try self.ssao_pass.set_vec3(name, self.ssao_samples[i]);
        }
    }
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
    \\
    \\void main() {
    \\  out_color = texture(u_rendered_tex, frag_uv);
    \\}
;
const lighting_frag =
    \\#version 460 core
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\
    \\uniform sampler2D u_pos_tex;
    \\uniform sampler2D u_normal_tex;
    \\uniform sampler2D u_base_tex;
    \\uniform sampler2D u_ssao_tex;
    \\
    \\uniform vec3 u_ambient;
    \\uniform vec3 u_light_color;
    \\uniform vec3 u_light_dir;
    \\uniform vec3 u_view_pos;
    \\
    \\void main() {
    \\  vec3 frag_color = texture(u_base_tex, frag_uv).rgb;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float ssao = texture(u_ssao_tex, frag_uv).x;
    \\  vec3 ambient = u_ambient * frag_color
++ (if (Options.enable_ssao) " * (1 - ssao);" else ";") ++
    \\
    \\  vec3 norm = normalize(frag_norm);
    \\  vec3 light_dir = u_light_dir;
    \\  float diff = max(dot(norm, light_dir), 0.0);
    \\  vec3 diffuse = u_light_color * diff * frag_color;
    \\
    \\  out_color = vec4(ambient + diffuse, 1);
    \\}
;
const ssao_frag =
    \\#version 460 core
++ std.fmt.comptimePrint("\n#define SAMPLES_COUNT {d}\n", .{SSAO_SAMPLES_COUNT}) ++
    \\out float out_ao;
    \\in vec2 frag_uv;
    \\
    \\uniform sampler2D u_pos_tex;
    \\uniform sampler2D u_normal_tex;
    \\uniform sampler2D u_noise_tex;
    \\uniform sampler2D u_depth_tex;
    \\
    \\uniform vec3 u_ssao_samples[SAMPLES_COUNT];
    \\uniform float u_radius = 1.0 / 4.0;
    \\uniform float u_bias = 0.15;
    \\uniform vec2 u_noise_scale;
    \\uniform mat4 u_vp;
    \\uniform mat4 u_view;
    \\
    \\void main() {
    \\  vec3 frag_pos = texture(u_pos_tex, frag_uv).xyz;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float frag_depth = texture(u_depth_tex, frag_uv).x;
    \\  vec3 random_vec = texture(u_noise_tex, frag_uv * u_noise_scale).xyz;
    \\
    \\  vec3 tangent = normalize(random_vec - frag_norm * dot(random_vec, frag_norm));
    \\  vec3 bitangent = cross(frag_norm, tangent);
    \\  mat3 TBN = mat3(tangent, bitangent, frag_norm);
    \\  out_ao = 0;
    \\  float avg_depth = 0;
    \\
    \\  for (int i = 0; i < SAMPLES_COUNT; i++) {
    \\    vec4 sample_uv = u_vp * vec4((TBN * u_ssao_samples[i]) * u_radius + frag_pos, 1);
    \\    sample_uv /= sample_uv.w; 
    \\    sample_uv = sample_uv * 0.5 + 0.5;
    \\    float sample_depth = texture(u_depth_tex, sample_uv.xy).x;
    \\    avg_depth += sample_depth;
    \\    float t = smoothstep(0.0, 1.0, u_radius / abs(sample_depth - frag_depth));
    \\    out_ao += (sample_depth + u_bias < frag_depth ? 1 : 0) * t;
    \\  }
    \\  out_ao = out_ao / SAMPLES_COUNT; 
    \\}
;

const blur_frag =
    \\#version 460 core
    \\uniform sampler2D u_tex;
    \\uniform int u_blur = 2;
    \\uniform vec2 u_tex_size;
    \\
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\
    \\void main() {
    \\  vec4 sum = vec4(0, 0, 0, 0);
    \\  for (int dx = -u_blur; dx < u_blur; dx++) {
    \\    for (int dy = -u_blur; dy < u_blur; dy++) {
    \\       sum += texture(u_tex, frag_uv + vec2(dx, dy) / u_tex_size);
    \\    }
    \\  }
    \\  out_color = sum / (u_blur * u_blur * 4);
    \\}
;
