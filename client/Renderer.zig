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
const Ecs = @import("libmine").Ecs;

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

block_renderer: BlockRenderer,

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

renderer_eid: Ecs.EntityRef,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.init_settings();
    try self.init_buffers();
    try self.block_renderer.init();
    try self.init_screen();
}

fn init_settings(self: *Renderer) !void {
    self.renderer_eid = try App.ecs().spawn();

    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".enable", "lighting_pass", "u_ssao_enabled", bool);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".blur", "ssao_blur_pass", "u_blur", i32);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".radius", "ssao_pass", "u_radius", f32);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".bias", "ssao_pass", "u_bias", f32);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".range_min", "ssao_pass", "u_range_min", f32);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".range_max", "ssao_pass", "u_range_max", f32);
    try self.on_setting_change_set_uniform(SSAO_SETTINGS ++ ".use_range", "ssao_pass", "u_use_range", bool);

    try self.on_setting_change_set_uniform(
        FXAA_SETTINGS ++ ".enable",
        "postprocessing_pass",
        "u_enable_fxaa",
        bool,
    );
    try self.on_setting_change_set_uniform(
        FXAA_SETTINGS ++ ".contrast",
        "postprocessing_pass",
        "u_fxaa_contrast",
        f32,
    );
    try self.on_setting_change_set_uniform(
        FXAA_SETTINGS ++ ".debug_outline",
        "postprocessing_pass",
        "u_fxaa_debug_outline",
        bool,
    );
}

fn on_setting_change_set_uniform(
    self: *Renderer,
    setting: []const u8,
    comptime pass_name: []const u8,
    comptime uniform: [:0]const u8,
    comptime T: type,
) !void {
    const evt = try App.settings().settings_change_event(T, setting);
    try App.ecs().add_event_listener(self.renderer_eid, T, *Renderer, evt, self, &(struct {
        fn callback(this: *Renderer, vals: []T) void {
            if (Options.renderer_log_settings_changed) {
                Log.log(.info, "Changed {s}.{s}", .{ pass_name, uniform });
            }
            const last = vals[vals.len - 1];
            const pass: *Shader = &@field(this, pass_name);
            const res = switch (T) {
                bool => pass.set_uint(uniform, if (last) 1 else 0),
                i32 => pass.set_int(uniform, last),
                f32 => pass.set_float(uniform, last),
                else => @compileError("Unsupported uniform type: " ++ @typeName(T)),
            };
            res catch |err| {
                Log.log(.warn, "Couldn't set '{s}' uniform for pass '{s}': {}", .{ uniform, pass_name, err });
            };
        }
    }.callback));
}

pub fn deinit(self: *Renderer) void {
    self.block_renderer.deinit();
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

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    const enable_ssao = App.settings().get_value(bool, SSAO_SETTINGS ++ ".enable") orelse false;
    const render_size = zm.Vec2f{ @floatFromInt(self.cur_width), @floatFromInt(self.cur_height) };

    try gl_call(gl.ClearDepth(0.0));
    try gl_call(gl.ClearColor(0, 0, 0, 1));
    try gl_call(gl.Enable(gl.DEPTH_TEST));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.g_buffer_fbo));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    try self.block_renderer.draw();

    if (enable_ssao) {
        try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.ssao_fbo));
        try gl_call(gl.Disable(gl.DEPTH_TEST));
        try self.ssao_pass.bind();
        try self.ssao_pass.set_mat4("u_proj", App.game_state().camera.proj_mat());
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
    try self.lighting_pass.set_vec3("u_view_pos", App.game_state().camera.pos);
    const light_dir_world = zm.vec.normalize(zm.Vec4f{ 1, 1, 1, 0 });
    const light_dir = App.game_state().camera.view_mat().multiplyVec4(light_dir_world);
    try self.lighting_pass.set_vec3("u_light_dir", zm.vec.xyz(light_dir));
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
        Log.log(.warn, "{*}: framebuffer 'g_buffer' incomplete!", .{self});
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
    }, &.{ 0, 1, 2, 0, 2, 3 }, gl.STATIC_DRAW);

    var render_sources: [2]Shader.Source = .{
        .{ .name = "render_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "render_frag", .sources = &.{lighting_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.lighting_pass = try .init(&render_sources);
    try self.lighting_pass.set_vec3("u_ambient", .{ 0.3, 0.3, 0.3 });
    try self.lighting_pass.set_vec3("u_light_color", .{ 1, 1, 0.9 });
    try self.lighting_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_base_tex", BASE_TEX_UNIFORM);
    try self.lighting_pass.set_int("u_ssao_tex", SSAO_TEX_UNIFORM);

    var post_sources: [2]Shader.Source = .{
        .{ .name = "post_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "post_frag", .sources = &.{postprocessing_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.postprocessing_pass = try .init(&post_sources);
    try self.postprocessing_pass.set_int("u_rendered_tex", RENDERED_TEX_UNIFORM);

    var ssao_sources: [2]Shader.Source = .{
        .{ .name = "ssao_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "ssao_frag", .sources = &.{ssao_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.ssao_pass = try .init(&ssao_sources);
    try self.ssao_pass.set_int("u_pos_tex", POSITION_TEX_UNIFORM);
    try self.ssao_pass.set_int("u_normal_tex", NORMAL_TEX_UNIFORM);
    try self.ssao_pass.set_int("u_noise_tex", NOISE_TEX_UNIFORM);

    var ssao_blur_sources: [2]Shader.Source = .{
        .{ .name = "ssao_blur_vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        .{ .name = "ssao_blur_frag", .sources = &.{blur_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.ssao_blur_pass = try .init(&ssao_blur_sources);
    try self.ssao_blur_pass.set_int("u_tex", SSAO_TEX_UNIFORM);

    for (0..SSAO_SAMPLES_COUNT) |i| {
        const phi = App.rng().float(f32) * std.math.pi * 0.4;
        const theta = App.rng().float(f32) * std.math.pi * 2.0;
        const r = App.rng().float(f32);
        const vec = zm.vec.normalize(zm.Vec3f{
            r * @sin(phi) * @cos(theta),
            r * @sin(phi) * @sin(theta),
            r * @cos(phi),
        });
        self.ssao_samples[i] = vec;
        const name = try std.fmt.allocPrintSentinel(App.frame_alloc(), "u_ssao_samples[{d}]", .{i}, 0);
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
    \\
    \\void main() {
    \\  vec3 frag_color = texture(u_base_tex, frag_uv).rgb;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float ssao = texture(u_ssao_tex, frag_uv).x;
    \\  vec3 ambient = u_ambient * frag_color * (u_ssao_enabled ? (1 - ssao) : 1);
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
    \\uniform float u_range_min = 5.0;
    \\uniform float u_range_max = 30.0;
    \\uniform vec2 u_noise_scale;
    \\uniform mat4 u_proj;
    \\uniform bool u_use_range = true;
    \\
    \\void main() {
    \\  out_ao = 0;
    \\  vec3 frag_pos = texture(u_pos_tex, frag_uv).xyz;
    \\  vec3 frag_norm = texture(u_normal_tex, frag_uv).xyz;
    \\  float frag_depth = -frag_pos.z;
    \\  if (u_use_range && (frag_depth < u_range_min || frag_depth > u_range_max)) return;
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
    \\  out_ao = (out_ao / SAMPLES_COUNT) * (u_use_range ? smoothstep(u_range_min, u_range_max, frag_depth) : 1); 
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
