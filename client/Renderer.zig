const App = @import("App.zig");
const Camera = @import("Camera.zig");
const gl = @import("gl");
const std = @import("std");
const World = @import("World.zig");
const SsboBindings = @import("SsboBindings.zig");
const util = @import("util.zig");
const gl_call = util.gl_call;
const Mesh = @import("Mesh.zig");
const Shader = @import("Shader.zig");
const zm = @import("zm");
const Options = @import("ClientOptions");
const c = @import("c.zig").c;
const OOM = std.mem.Allocator.Error;
const GlError = util.GlError;
const logger = std.log.scoped(.renderer);

const SSAO_SAMPLES_COUNT = 8;
const NOISE_SIZE = 4;
const SSAO_SETTINGS = ".main.renderer.ssao";
const FXAA_SETTINGS = ".main.renderer.fxaa";

pub const POSITION_TEX_ATTACHMENT = 0;
pub const NORMAL_TEX_ATTACHMENT = 1;
pub const BASE_TEX_ATTACHMENT = 2;
pub const SSAO_TEX_ATTACHMENT = 0;
const RENDERED_TEX_ATTACHMENT = 0;

const POSITION_TEX_UNIFORM = 0;
const NORMAL_TEX_UNIFORM = 1;
const BASE_TEX_UNIFORM = 2;
const SSAO_TEX_UNIFORM = 3;
const RENDERED_TEX_UNIFORM = 5;
const NOISE_TEX_UNIFORM = 6;

cur_width: i32,
cur_height: i32,

g_buffer_fbo: gl.uint,
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
steps: std.ArrayList(GeometryStep),

const Renderer = @This();

const GeometryStep = struct {
    data: *anyopaque,
    callback: *const fn (*anyopaque, *Camera) App.UnhandledError!void,
};

pub fn init(self: *Renderer) !void {
    self.steps = .empty;
    try self.init_buffers();
    try self.init_screen();
    try self.init_settings();
}

fn init_settings(self: *Renderer) !void {
    try self.lighting_pass.observe_settings(
        SSAO_SETTINGS ++ ".enable",
        bool,
        "u_ssao_enabled",
        @src(),
    );
    try self.ssao_blur_pass.observe_settings(SSAO_SETTINGS ++ ".blur", i32, "u_blur", @src());
    try self.ssao_pass.observe_settings(SSAO_SETTINGS ++ ".radius", f32, "u_radius", @src());
    try self.ssao_pass.observe_settings(SSAO_SETTINGS ++ ".bias", f32, "u_bias", @src());

    try self.postprocessing_pass.observe_settings(
        FXAA_SETTINGS ++ ".enable",
        bool,
        "u_enable_fxaa",
        @src(),
    );
    try self.postprocessing_pass.observe_settings(
        FXAA_SETTINGS ++ ".contrast",
        f32,
        "u_fxaa_contrast",
        @src(),
    );
    try self.postprocessing_pass.observe_settings(
        FXAA_SETTINGS ++ ".debug_outline",
        bool,
        "u_fxaa_debug_outline",
        @src(),
    );
}

pub fn deinit(self: *Renderer) void {
    gl.DeleteFramebuffers(1, @ptrCast(&self.g_buffer_fbo));
    gl.DeleteFramebuffers(1, @ptrCast(&self.render_fbo));
    gl.DeleteFramebuffers(1, @ptrCast(&self.ssao_fbo));
    gl.DeleteFramebuffers(1, @ptrCast(&self.ssao_blur_fbo));

    gl.DeleteRenderbuffers(1, @ptrCast(&self.depth_rbo));

    gl.DeleteTextures(1, @ptrCast(&self.rendered_tex));
    gl.DeleteTextures(1, @ptrCast(&self.position_tex));
    gl.DeleteTextures(1, @ptrCast(&self.normal_tex));
    gl.DeleteTextures(1, @ptrCast(&self.base_tex));

    gl.DeleteTextures(1, @ptrCast(&self.ssao_tex));
    gl.DeleteTextures(1, @ptrCast(&self.ssao_blur_tex));
    gl.DeleteTextures(1, @ptrCast(&self.noise_tex));

    self.screen_quad.deinit();
    self.postprocessing_pass.deinit();
    self.lighting_pass.deinit();
    self.ssao_pass.deinit();
    self.ssao_blur_pass.deinit();
}

pub fn add_step(self: *Renderer, comptime fptr: anytype, args: anytype) !void {
    const Args = @TypeOf(args);
    const Closure = struct {
        args: Args,
        fn callback(this: *@This(), camera: *Camera) App.UnhandledError!void {
            try @call(.auto, fptr, this.args ++ .{camera});
        }
    };
    const closure = try App.static_alloc().create(Closure);
    closure.args = args;

    try self.steps.append(App.static_alloc(), .{
        .data = @ptrCast(closure),
        .callback = @ptrCast(&Closure.callback),
    });
}

pub fn draw(self: *Renderer, camera: *Camera) (OOM || GlError)!void {
    const enable_ssao = App.settings().get_value(bool, SSAO_SETTINGS ++ ".enable");
    const render_size = zm.Vec2f{
        @floatFromInt(self.cur_width),
        @floatFromInt(self.cur_height),
    };

    try gl_call(gl.ClearDepth(0.0));
    try gl_call(gl.ClearColor(0, 0, 0, 1));
    try gl_call(gl.Enable(gl.DEPTH_TEST));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.g_buffer_fbo));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    for (self.steps.items) |s| try s.callback(s.data, camera);

    if (enable_ssao) {
        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_fbo));
        try gl_call(gl.Disable(gl.DEPTH_TEST));
        try self.ssao_pass.bind();
        try self.ssao_pass.set_mat4("u_proj", camera.proj_mat());
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
        try self.screen_quad.draw(gl.TRIANGLES);

        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_blur_fbo));
        try gl_call(gl.Disable(gl.DEPTH_TEST));
        try self.ssao_blur_pass.bind();
        try self.ssao_blur_pass.set_vec2("u_tex_size", render_size);
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + SSAO_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_tex));
        try self.screen_quad.draw(gl.TRIANGLES);
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.render_fbo));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.lighting_pass.bind();
    try self.lighting_pass.set_vec2("u_tex_size", render_size);
    try self.lighting_pass.set_vec3("u_view_pos", camera.frustum.pos);
    try self.lighting_pass.set_float("u_time", App.elapsed_time());
    // TODO: find a better way to get this value
    const center_chunk, const chunk_radius = @import("Game.zig").instance().world
        .currently_loaded_region();
    try self.lighting_pass.set(
        "u_chunk_radius",
        .{ chunk_radius[0], chunk_radius[1], chunk_radius[2] },
        "3i",
    );
    try self.lighting_pass.set(
        "u_center_chunk",
        .{ center_chunk[0], center_chunk[1], center_chunk[2] },
        "3i",
    );

    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + POSITION_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NORMAL_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_tex));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + BASE_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_tex));

    if (enable_ssao) {
        try gl_call(gl.ActiveTexture(gl.TEXTURE0 + SSAO_TEX_UNIFORM));
        try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.ssao_blur_tex));
    }
    try self.screen_quad.draw(gl.TRIANGLES);
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
    try gl_call(gl.Disable(gl.DEPTH_TEST));

    try self.postprocessing_pass.bind();
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + RENDERED_TEX_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
    try self.postprocessing_pass.set_vec2("u_render_size", render_size);
    try self.screen_quad.draw(gl.TRIANGLES);
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
}

pub fn resize_framebuffers(self: *Renderer, w: i32, h: i32) !void {
    if (self.cur_width == w and self.cur_height == h) return;
    self.cur_width = w;
    self.cur_height = h;

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.g_buffer_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.position_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE));
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

    try gl_call(gl.BindRenderbuffer(gl.RENDERBUFFER, self.depth_rbo));
    try gl_call(gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT, w, h));
    try gl_call(gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, self.depth_rbo));

    const g_buffer_draw_buffers: []const gl.uint = &.{
        gl.COLOR_ATTACHMENT0 + POSITION_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + NORMAL_TEX_ATTACHMENT,
        gl.COLOR_ATTACHMENT0 + BASE_TEX_ATTACHMENT,
    };
    try gl_call(gl.DrawBuffers(@intCast(g_buffer_draw_buffers.len), @ptrCast(g_buffer_draw_buffers)));
    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        std.log.warn("{*}: framebuffer 'g_buffer' incomplete!", .{self});
    }

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
        std.log.warn("{*}: framebuffer 'ssao_fbo' incomplete!", .{self});
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
        std.log.warn("{*}: framebuffer 'ssao_blur_fbo' incomplete!", .{self});
    }

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.render_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.rendered_tex));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        gl.COLOR_ATTACHMENT0 + RENDERED_TEX_ATTACHMENT,
        gl.TEXTURE_2D,
        self.rendered_tex,
        0,
    ));

    if (try gl_call(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)) {
        std.log.warn("{*}: framebuffer 'render_fbo' incomplete!", .{self});
    }
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
}

pub fn on_frame_start(self: *Renderer) !void {
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

    const textures: []const [:0]const u8 = &(.{
        "position_tex",
        "normal_tex",
        "base_tex",
        "ssao_tex",
        "ssao_blur_tex",
    });

    inline for (textures) |name| {
        c.igText(name);
        const tex: c.ImTextureRef = .{ ._TexID = @intCast(@field(self, name)) };
        c.igImage(tex, size, uv_min, uv_max);
    }
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.g_buffer_fbo)));
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.render_fbo)));
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ssao_fbo)));
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.ssao_blur_fbo)));

    try gl_call(gl.GenRenderbuffers(1, @ptrCast(&self.depth_rbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.rendered_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.position_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.normal_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.base_tex)));

    try gl_call(gl.GenTextures(1, @ptrCast(&self.ssao_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.ssao_blur_tex)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.noise_tex)));

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

    try self.resize_framebuffers(640, 480);
}

fn init_screen(self: *Renderer) !void {
    self.screen_quad = try Mesh.init(QuadVert, u8, &.{
        .{ .pos = .{ .x = -1, .y = -1 }, .uv = .{ .u = 0, .v = 0 } },
        .{ .pos = .{ .x = -1, .y = 1 }, .uv = .{ .u = 0, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = 1 }, .uv = .{ .u = 1, .v = 1 } },
        .{ .pos = .{ .x = 1, .y = -1 }, .uv = .{ .u = 1, .v = 0 } },
    }, &.{ 0, 3, 2, 0, 2, 1 }, gl.STATIC_DRAW);

    var render_sources: [2]Shader.Source = .{
        .{ .name = "render_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "render_frag", .sources = &.{lighting_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.lighting_pass = try .init(&render_sources, "lighting_pass");
    try self.lighting_pass.set_vec3("u_ambient", .{ 0.3, 0.3, 0.3 });
    try self.lighting_pass.set_vec3("u_light_color", .{ 1, 1, 1 });
    const light_dir_world = zm.vec.normalize(zm.Vec3f{ 1, 1, 1 });
    try self.lighting_pass.set_vec3("u_light_dir", light_dir_world);

    try self.lighting_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_base_tex", BASE_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_ssao_tex", SSAO_TEX_UNIFORM);

    var post_sources: [2]Shader.Source = .{
        .{ .name = "post_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "post_frag", .sources = &.{postprocessing_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.postprocessing_pass = try .init(&post_sources, "postprocessing_pass");
    try self.postprocessing_pass.set_int("u_rendered_tex", RENDERED_TEX_UNIFORM);

    var ssao_sources: [2]Shader.Source = .{
        .{ .name = "ssao_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "ssao_frag", .sources = &.{ssao_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.ssao_pass = try .init(&ssao_sources, "ssao_pass");
    try self.ssao_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.ssao_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.ssao_pass.set_int("u_noise_tex", NOISE_TEX_UNIFORM);

    var ssao_blur_sources: [2]Shader.Source = .{
        .{ .name = "ssao_blur_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "ssao_blur_frag", .sources = &.{blur_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.ssao_blur_pass = try .init(&ssao_blur_sources, "ssao_blur_pass");
    try self.ssao_blur_pass.set_int("u_tex", SSAO_TEX_UNIFORM);

    inline for (0..SSAO_SAMPLES_COUNT) |i| {
        const phi = App.rng().float(f32) * std.math.pi * 0.4;
        const theta = App.rng().float(f32) * std.math.pi * 2.0;
        const r = App.rng().float(f32);
        const vec = zm.vec.normalize(zm.Vec3f{
            r * @sin(phi) * @cos(theta),
            r * @sin(phi) * @sin(theta),
            r * @cos(phi),
        });
        self.ssao_samples[i] = vec;
        const name = std.fmt.comptimePrint("u_ssao_samples[{d}]", .{i});
        try self.ssao_pass.set_vec3(name, self.ssao_samples[i]);
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

pub const LightLevelInfo = packed struct(u32) {
    color: u12 = 0,
    level: u4 = 0,
    _unused: u16 = 0x463a,
};

pub const LightList = u32;
pub const ChunkData = extern struct {
    x: i32,
    y: i32,
    z: i32,
    light_levels: u32,
    light_lists: u32,
    no_lights: u32 = 1,
    unused1: u32 = 0xbabacaca,
    unused2: u32 = 0xfefefafa,

    pub fn define() [:0]const u8 {
        return 
        \\
        \\struct Chunk {
        \\  int x;
        \\  int y;
        \\  int z;
        \\  uint light_levels;
        \\  uint light_lists;
        \\  uint no_lights;
        \\  uint unused;
        \\  uint unused2;
        \\};
        \\
        ;
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
    \\uniform sampler2D u_rendered_tex;
    \\uniform vec2 u_render_size;
    \\
    \\uniform float u_fxaa_contrast = 1.0;
    \\uniform bool u_enable_fxaa = true;
    \\uniform bool u_fxaa_debug_outline = false;
    \\
    \\in vec2 frag_uv;
    \\out vec4 out_color;
    \\
    \\float edge_detect_weights[9] = {-1, -1, -1, 2, 2, 2, -1, -1, -1};
    \\vec4 edge_detect(bool vertical) {
    \\  vec4 sum = vec4(0);
    \\  int k = 0;
    \\  for (int i = -1; i <= 1; i++) {
    \\    for (int j = -1; j <= 1; j++) {
    \\      vec2 d = (vertical ? vec2(i, j) : vec2(j, i));
    \\      sum += edge_detect_weights[k] * texture(u_rendered_tex, frag_uv + d / u_render_size);
    \\      k++;
    \\    }
    \\  }
    \\  return sum;
    \\}
    \\
    \\float sample_luminance(vec2 uv) {
    \\  vec4 s = texture(u_rendered_tex, uv);
    \\  return max(s.r, max(s.g, s.b));
    \\}
    \\
    \\vec4 fxaa() {
    \\  float u = sample_luminance(frag_uv + vec2(0, 1) / u_render_size);  
    \\  float d = sample_luminance(frag_uv - vec2(0, 1) / u_render_size);  
    \\  float l = sample_luminance(frag_uv - vec2(1, 0) / u_render_size);  
    \\  float r = sample_luminance(frag_uv + vec2(1, 0) / u_render_size);  
    \\  float c = sample_luminance(frag_uv);  
    \\
    \\  float min_lum = min(min(u, d), min(l, min(c, r)));
    \\  float max_lum = max(max(u, d), max(l, max(c, r)));
    \\  float contrast = max_lum - min_lum;
    \\  if (contrast < u_fxaa_contrast) return (u_fxaa_debug_outline ? vec4(0) : texture(u_rendered_tex, frag_uv));
    \\
    \\  float lu = sample_luminance(frag_uv + vec2(-1, 1) / u_render_size);
    \\  float lb = sample_luminance(frag_uv + vec2(-1, -1) / u_render_size);
    \\  float ru = sample_luminance(frag_uv + vec2(1, 1) / u_render_size);
    \\  float rb = sample_luminance(frag_uv + vec2(1, -1) / u_render_size);
    \\
    \\  float f = smoothstep(0, 1, abs((2 * (u + d + l + r) + (lu + lb + ru + rb)) / 12 - c) / contrast);
    \\  float vert = length(edge_detect(true));
    \\  float horiz = length(edge_detect(false));
    \\
    \\  if (vert > horiz) {
    \\      vec4 l = texture(u_rendered_tex, frag_uv - vec2(f, 0) / u_render_size);
    \\      vec4 r = texture(u_rendered_tex, frag_uv + vec2(f, 0) / u_render_size);
    \\      return (l + r) / 2;
    \\  } else {
    \\      vec4 d = texture(u_rendered_tex, frag_uv - vec2(0, f) / u_render_size);
    \\      vec4 u = texture(u_rendered_tex, frag_uv + vec2(0, f) / u_render_size);
    \\      return (d + u) / 2;
    \\  }
    \\}
    \\
    \\void main() {
    \\  out_color = (u_enable_fxaa ? fxaa() : texture(u_rendered_tex, frag_uv));
    \\}
;
const lighting_frag =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define CHUNK_DATA_BINDING {d}\n", .{SsboBindings.CHUNK_DATA}) ++
    std.fmt.comptimePrint("#define LIGHT_LEVELS_BINDING {d}\n", .{SsboBindings.LIGHT_LEVELS}) ++
    std.fmt.comptimePrint("#define LIGHT_LISTS_BINDING {d}\n", .{SsboBindings.LIGHT_LISTS}) ++
    \\
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
    \\uniform bool u_ssao_enabled;
    \\uniform vec2 u_tex_size;
    \\uniform float u_time;
    \\uniform ivec3 u_chunk_radius;
    \\uniform ivec3 u_center_chunk;
    \\
++ ChunkData.define() ++
    \\
    \\layout (std430, binding = CHUNK_DATA_BINDING) readonly buffer ChunkData {
    \\ Chunk chunks[];
    \\};
    \\
    \\layout (std430, binding = LIGHT_LEVELS_BINDING) readonly buffer LightLevels {
    \\  uint light_levels[];
    \\};
    \\
    \\layout (std430, binding = LIGHT_LISTS_BINDING) readonly buffer LightLists {
    \\  uint light_lists[];
    \\};
    \\
    \\vec3 rgb_to_hsv(vec3 rgb) {
    \\  float cmax = max(rgb.r, max(rgb.b, rgb.g));
    \\  float cmin = min(rgb.r, min(rgb.b, rgb.g));
    \\  float delta = cmax - cmin;
    \\  float h = (delta == 0 ? 0.0
    \\            : cmax == rgb.r ? (60 * mod((rgb.g - rgb.b) / delta, 6)) 
    \\            : cmax == rgb.g ? (60 * ((rgb.b - rgb.r) / delta + 2.0))
    \\            : (60 * ((rgb.r - rgb.g) / delta + 4.0)));
    \\  float s = (cmax == 0 ? 0 : delta / cmax);
    \\  float v = cmax;
    \\  return vec3(h, s, v);
    \\}
    \\
    \\vec3 hsv_to_rgb(vec3 hsv) {
    \\  float h = mod(hsv.r, 360.0);
    \\  float s = hsv.g;
    \\  float v = hsv.b;
    \\  float c = v * s;
    \\  float x = c * (1.0 - abs(mod(h / 60, 2) - 1));
    \\  float m = v - c;
    \\ 
    \\  float r = 0, g = 0, b = 0;
    \\  if (h >= 0 && h < 60.0) {
    \\      r = c; g = x; b = 0.0;
    \\  } else if (h >= 60.0 && h < 120.0) {
    \\      r = x; g = c; b = 0.0;
    \\  } else if (h >= 120.0 && h < 180.0) {
    \\      r = 0.0; g = c; b = x;
    \\  } else if (h >= 180.0 && h < 240.0) {
    \\      r = 0.0; g = x; b = c;
    \\  } else if (h >= 240.0 && h < 300.0) {
    \\      r = x; g = 0.0; b = c;
    \\  } else if (h >= 300.0 && h < 360.0) {
    \\      r = c; g = 0.0; b = x;
    \\  }
    \\  return vec3(r, g, b) + vec3(m);
    \\}
    \\
    \\vec3 sample_light() {
    \\  ivec2 texture_coords = ivec2(frag_uv * u_tex_size);
    // TODO: 0.75 is a hacky number to get stairs working,
    // if a block is lower than stairs it will not get lit
    \\  vec3 pos = texelFetch(u_pos_tex, texture_coords, 0).xyz + 
    \\             texelFetch(u_normal_tex, texture_coords, 0).xyz * 0.75;
    \\  ivec3 world_pos = ivec3(floor(pos));
    // TODO: bad code but it doesnt seem to do @divFloor() properly
    \\  ivec3 chunk_pos = ivec3(
    \\    world_pos.x > 0 ? world_pos.x / 16 : (world_pos.x + 1) / 16 - 1,
    \\    world_pos.y > 0 ? world_pos.y / 16 : (world_pos.y + 1) / 16 - 1,
    \\    world_pos.z > 0 ? world_pos.z / 16 : (world_pos.z + 1) / 16 - 1
    \\  );
    \\  chunk_pos.x = (world_pos.x == 0 ? 0 : chunk_pos.x);
    \\  chunk_pos.y = (world_pos.y == 0 ? 0 : chunk_pos.y);
    \\  chunk_pos.z = (world_pos.z == 0 ? 0 : chunk_pos.z);
    \\
    \\  ivec3 chunk_offset = chunk_pos - u_center_chunk;
    \\  chunk_offset += u_chunk_radius;
    \\  uvec3 size = u_chunk_radius * 2 + 1;
    \\  uint chunk_idx = chunk_offset.x * size.y * size.z + 
    \\                   chunk_offset.y * size.z + chunk_offset.z;
    \\  Chunk chunk = chunks[chunk_idx];
    \\  if (chunk.no_lights == 1) return vec3(0);
    \\  
    \\  uvec3 block_coords = uvec3(mod(world_pos, 16));
    \\  uint idx = block_coords.y * 16 * 16 + block_coords.z * 16 + block_coords.x;
    \\  uint start = light_lists[chunk.light_lists + idx];
    \\  uint end = light_lists[chunk.light_lists + idx + 1];
    \\  uint length = end - start;
    \\  if (length == 0) return vec3(0);
    \\
    \\  vec3 res = vec3(0);
    \\  for (uint i = 0; i < length; i++) {
    \\    uint entry = light_levels[chunk.light_levels + i + start];
    \\    uint level = (entry >> uint(12)) & uint(0xF);
    \\    uint r = (entry >> uint(8)) & uint(0xF);
    \\    uint g = (entry >> uint(4)) & uint(0xF);
    \\    uint b = (entry >> uint(0)) & uint(0xF);
    \\    vec3 rgb = vec3(float(r), float(g), float(b));
    \\    float a = float(level) / 15.0;
    \\    res = max(res, rgb * a);
    \\  }
    \\  return res;
    \\}
    \\
    \\void main() {
    \\  vec3 frag_color = texture(u_base_tex, frag_uv).rgb;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float ssao = texture(u_ssao_tex, frag_uv).x;
    \\  vec3 light_color = sample_light();
    \\
    \\  vec3 ambient = (u_ambient + light_color) * frag_color * (u_ssao_enabled ? (1 - ssao) : 1);
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
    \\
    \\uniform vec3 u_ssao_samples[SAMPLES_COUNT];
    \\uniform float u_radius = 1.0 / 8.0;
    \\uniform float u_bias = 0.1;
    \\uniform vec2 u_noise_scale;
    \\uniform mat4 u_proj;
    \\
    \\void main() {
    \\  out_ao = 0;
    \\  vec3 frag_pos = texture(u_pos_tex, frag_uv).xyz;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float frag_depth = -frag_pos.z;
    \\  vec3 random_vec = texture(u_noise_tex, frag_uv * u_noise_scale).xyz;
    \\
    \\  vec3 tangent = normalize(random_vec - frag_norm * dot(random_vec, frag_norm));
    \\  vec3 bitangent = cross(frag_norm, tangent);
    \\  mat3 TBN = mat3(tangent, bitangent, frag_norm);
    \\
    \\  for (int i = 0; i < SAMPLES_COUNT; i++) {
    \\    vec4 sample_uv = u_proj * vec4((TBN * u_ssao_samples[i]) * u_radius + frag_pos, 1);
    \\    sample_uv /= sample_uv.w; 
    \\    sample_uv = sample_uv * 0.5 + 0.5;
    \\    float sample_depth = -texture(u_pos_tex, sample_uv.xy).z;
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
    \\  for (int dx = -u_blur; dx <= u_blur; dx++) {
    \\    for (int dy = -u_blur; dy <= u_blur; dy++) {
    \\       sum += texture(u_tex, frag_uv + vec2(dx, dy) / u_tex_size);
    \\    }
    \\  }
    \\  out_color = sum / (u_blur * u_blur * 4);
    \\}
;
