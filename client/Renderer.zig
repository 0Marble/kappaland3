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

const BLOCK_COORDS_ATTACHMENT = gl.COLOR_ATTACHMENT0;
const POS_ATTACHMENT = gl.COLOR_ATTACHMENT1;
const NORMAL_ATTACHMENT = gl.COLOR_ATTACHMENT2;
const BASE_COLOR_ATTACHMENT = gl.COLOR_ATTACHMENT3;
const POS_TEXTURE_UNIFORM = 0;
const NORMAL_TEXTURE_UNIFORM = 1;
const BASE_COLOR_TEXTURE_UNIFORM = 2;

block_renderer: BlockRenderer,

gbuffer_fbo: gl.uint,
depth_rbo: gl.uint,
block_coord_texture: gl.uint,
pos_texture: gl.uint,
normal_texture: gl.uint,
base_color_texture: gl.uint,

lighting_pass: Shader,
screen_quad: Mesh,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    try self.init_buffers();
    try self.block_renderer.init();
    try self.init_lighting_pass();
}

pub fn deinit(self: *Renderer) void {
    self.screen_quad.deinit();
    self.lighting_pass.deinit();

    self.block_renderer.deinit();

    gl.DeleteFramebuffers(1, @ptrCast(&self.gbuffer_fbo));
    gl.DeleteRenderbuffers(1, @ptrCast(&self.depth_rbo));
    gl.DeleteTextures(1, @ptrCast(&self.block_coord_texture));
    gl.DeleteTextures(1, @ptrCast(&self.base_color_texture));
    gl.DeleteTextures(1, @ptrCast(&self.pos_texture));
    gl.DeleteTextures(1, @ptrCast(&self.normal_texture));
}

pub fn upload_chunk(self: *Renderer, chunk: *Chunk) !void {
    try self.block_renderer.upload_chunk(chunk);
}

pub fn draw(self: *Renderer) !void {
    try gl_call(gl.ClearDepth(0.0));

    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.gbuffer_fbo));
    try gl_call(gl.ClearColor(0, 0, 0, 1));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));
    try self.block_renderer.draw();
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));

    try gl_call(gl.ClearColor(0.4, 0.4, 0.4, 1.0));
    try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + POS_TEXTURE_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.pos_texture));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + NORMAL_TEXTURE_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_texture));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + BASE_COLOR_TEXTURE_UNIFORM));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_color_texture));

    try self.lighting_pass.bind();
    try self.screen_quad.draw(gl.TRIANGLES);

    try App.gui().draw();
}

pub fn resize_gbuffer(self: *Renderer, w: i32, h: i32) !void {
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, self.gbuffer_fbo));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.block_coord_texture));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA32I, w, h, 0, gl.RGBA_INTEGER, gl.INT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        BLOCK_COORDS_ATTACHMENT,
        gl.TEXTURE_2D,
        self.gbuffer_fbo,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.pos_texture));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        POS_ATTACHMENT,
        gl.TEXTURE_2D,
        self.gbuffer_fbo,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.normal_texture));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        NORMAL_ATTACHMENT,
        gl.TEXTURE_2D,
        self.gbuffer_fbo,
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, self.base_color_texture));
    try gl_call(gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, null));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.FramebufferTexture2D(
        gl.FRAMEBUFFER,
        BASE_COLOR_ATTACHMENT,
        gl.TEXTURE_2D,
        self.gbuffer_fbo,
        0,
    ));

    const attachments: []const gl.uint = &.{
        BLOCK_COORDS_ATTACHMENT,
        POS_ATTACHMENT,
        NORMAL_ATTACHMENT,
        BASE_COLOR_ATTACHMENT,
    };
    try gl_call(gl.DrawBuffers(@intCast(attachments.len), @ptrCast(attachments)));

    try gl_call(gl.BindRenderbuffer(gl.RENDERBUFFER, self.depth_rbo));
    try gl_call(gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT, w, h));
    try gl_call(gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, self.depth_rbo));

    if (gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) {
        Log.log(.warn, "{*}: Framebuffer incomplete", .{self});
    }

    try gl_call(gl.BindTexture(gl.TEXTURE_2D, 0));
    try gl_call(gl.BindRenderbuffer(gl.RENDERBUFFER, 0));
    try gl_call(gl.BindFramebuffer(gl.FRAMEBUFFER, 0));
}

fn init_buffers(self: *Renderer) !void {
    try gl_call(gl.GenFramebuffers(1, @ptrCast(&self.gbuffer_fbo)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.block_coord_texture)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.pos_texture)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.normal_texture)));
    try gl_call(gl.GenTextures(1, @ptrCast(&self.base_color_texture)));
    try gl_call(gl.GenRenderbuffers(1, @ptrCast(&self.depth_rbo)));

    try self.resize_gbuffer(640, 480);
}

fn init_lighting_pass(self: *Renderer) !void {
    const Vert = struct {
        pos: struct { x: f32, y: f32 },
        uv: struct { u: f32, v: f32 },

        pub fn setup_attribs() !void {
            inline for (.{ "pos", "uv" }, 0..) |field, i| {
                const Attrib = @FieldType(@This(), field);
                try gl_call(gl.VertexAttribPointer(
                    i,
                    @intCast(std.meta.fields(Attrib).len),
                    gl.FLOAT,
                    gl.FALSE,
                    @sizeOf(@This()),
                    @offsetOf(@This(), field),
                ));
                try gl_call(gl.EnableVertexAttribArray(i));
            }
        }
    };

    self.screen_quad = try .init(
        Vert,
        u8,
        &.{
            Vert{ .pos = .{ .x = -1, .y = -1 }, .uv = .{ .u = 0, .v = 0 } },
            Vert{ .pos = .{ .x = -1, .y = 1 }, .uv = .{ .u = 0, .v = 1 } },
            Vert{ .pos = .{ .x = 1, .y = 1 }, .uv = .{ .u = 1, .v = 1 } },
            Vert{ .pos = .{ .x = 1, .y = -1 }, .uv = .{ .u = 1, .v = 0 } },
        },
        &.{ 0, 1, 2, 0, 2, 3 },
        gl.STATIC_DRAW,
    );

    var sources: [2]Shader.Source = .{
        Shader.Source{
            .name = "lighting_pass_vert",
            .sources = &.{VERT_SRC},
            .kind = gl.VERTEX_SHADER,
        },
        Shader.Source{
            .name = "lighting_pass_frag",
            .sources = &.{FRAG_SRC},
            .kind = gl.FRAGMENT_SHADER,
        },
    };
    self.lighting_pass = try .init(&sources);
    try self.lighting_pass.set_vec3("u_ambient", .{ 0.1, 0.1, 0.1 });
    try self.lighting_pass.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 2, 1, 1 }));
    try self.lighting_pass.set_vec3("u_light_color", .{ 1, 1, 0.9 });
    try self.lighting_pass.set_int("u_pos", POS_TEXTURE_UNIFORM);
    try self.lighting_pass.set_int("u_normal", NORMAL_TEXTURE_UNIFORM);
    try self.lighting_pass.set_int("u_base_color", BASE_COLOR_TEXTURE_UNIFORM);
}

const VERT_SRC =
    \\#version 460 core
    \\layout (location = 0) in vec2 vert_pos;
    \\layout (location = 1) in vec2 vert_uv;
    \\out vec2 frag_uv;
    \\void main() {
    \\  gl_Position = vec4(vert_pos, 1, 1);
    \\  frag_uv = vert_uv;
    \\}
;

const FRAG_SRC =
    \\#version 460 core
    \\out vec4 out_color;
    \\
    \\in vec2 frag_uv;
    \\
    \\uniform sampler2D u_pos;
    \\uniform sampler2D u_normal;
    \\uniform sampler2D u_base_color;
    \\
    \\uniform vec3 u_ambient;
    \\uniform vec3 u_light_color;
    \\uniform vec3 u_light_dir;
    \\uniform vec3 u_view_pos;
    \\
    \\void main() {
    \\  vec3 frag_pos = texture(u_pos, frag_uv).rgb;
    \\  vec3 frag_norm = texture(u_normal, frag_uv).rgb;
    \\  vec3 frag_color = texture(u_base_color, frag_uv).rgb;
    \\
    \\  vec3 ambient = u_ambient * frag_color;
    \\
    \\  vec3 norm = normalize(frag_norm);
    \\  vec3 light_dir = u_light_dir;
    \\  float diff = max(dot(norm, light_dir), 0.0);
    \\  vec3 diffuse = u_light_color * diff * frag_color;
    \\
    \\   out_color = vec4(ambient + diffuse, 1);
    \\}
;
