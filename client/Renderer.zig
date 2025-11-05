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

ray: zm.Rayf,
ray_mesh: Mesh,
ray_shader: Shader,

const Renderer = @This();
pub fn init(self: *Renderer) !void {
    self.cur_width = 640;
    self.cur_height = 480;
    try self.block_renderer.init();

    const Vert = struct {
        x: f32,
        y: f32,
        z: f32,

        pub fn setup_attribs() !void {
            try gl_call(gl.VertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, @sizeOf(@This()), 0));
            try gl_call(gl.EnableVertexAttribArray(0));
        }
    };
    self.ray = .init(@splat(100), @splat(100));
    self.ray_mesh = try .init(
        Vert,
        u8,
        &.{ Vert{ .x = 0, .y = 0, .z = 0 }, Vert{ .x = 1, .y = 1, .z = 1 } },
        &.{ 0, 1 },
        gl.STATIC_DRAW,
    );
    var sources: [2]Shader.Source = .{
        Shader.Source{ .sources = &.{ray_vert}, .kind = gl.VERTEX_SHADER },
        Shader.Source{ .sources = &.{ray_frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.ray_shader = try .init(&sources);
}

pub fn deinit(self: *Renderer) void {
    self.ray_mesh.deinit();
    self.ray_shader.deinit();
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

    try self.ray_shader.bind();
    const model = zm.Mat4f.translationVec3(self.ray.origin)
        .multiply(zm.Mat4f.scalingVec3(self.ray.direction));
    const mvp = App.game_state().camera.as_mat().multiply(model);
    try self.ray_shader.set_mat4("u_mvp", mvp);
    try self.ray_mesh.draw(gl.LINES);

    try App.gui().draw();
}

pub fn resize_framebuffers(self: *Renderer, w: i32, h: i32) !void {
    if (self.cur_width == w and self.cur_height == h) return;
    self.cur_width = w;
    self.cur_height = h;
}

const ray_vert =
    \\#version 460 core
    \\in vec3 vpos;
    \\uniform mat4 u_mvp;
    \\void main() {gl_Position = u_mvp*vec4(vpos,1); }
;
const ray_frag =
    \\#version 460 core 
    \\out vec4 color;
    \\void main() { color = vec4(1,0,0,1); }
;
