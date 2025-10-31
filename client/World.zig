const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const gl_call = @import("util.zig").gl_call;
const Shader = @import("Shader.zig");

const CHUNK_SIZE = 16;

pub const BlockStore = struct {};

const BlockId = enum(u32) {
    air = 0,
    stone = 1,
    dirt = 2,
    grass = 3,
    _,
};

const vert =
    \\#version 460 core
    \\layout (location = 0) in uint vert_data; // nnnxxxxx|000yyyyy|000zzzzz|texture
    \\
    \\uniform ivec3 u_chunk_coord;
    \\uniform mat4 u_vp;
    \\
    \\out vec3 frag_norm;
    \\out vec3 frag_color;
    \\out vec3 frag_pos;
    \\
    \\vec3 normals[6] = {
    \\  vec3(0, 0, 1),
    \\  vec3(0, 0, -1),
    \\  vec3(1, 0, 0),
    \\  vec3(-1, 0, 0),
    \\  vec3(0, 1, 0),
    \\  vec3(0, -1, 0)
    \\};
    \\vec3 colors[4] = {
    \\  vec3(0, 0, 0),
    \\  vec3(0.2,0.2,0.2),
    \\  vec3(0.4,0.2,0),
    \\  vec3(0.1,0.4,0.1),
    \\};
    \\
    \\void main() {
    \\  uint n = (vert_data & 0xE0000000) >> 29;
    \\  uint x = (vert_data & 0x1F000000) >> 24;
    \\  uint y = (vert_data & 0x001F0000) >> 16;
    \\  uint z = (vert_data & 0x00001F00) >> 8;
    \\  uint t = (vert_data & 0x000000FF) >> 0;
    \\  frag_pos = vec3(x,y,z) + u_chunk_coord * 16;
    \\  frag_color = colors[t];
    \\  frag_norm = normals[n];
    \\  gl_Position = u_vp * vec4(frag_pos, 1);
    \\}
;
const frag =
    \\#version 460 core
    \\
    \\uniform vec3 u_ambient;
    \\uniform vec3 u_light_color;
    \\uniform vec3 u_light_dir;
    \\uniform vec3 u_view_pos;
    \\
    \\in vec3 frag_color;
    \\in vec3 frag_norm;
    \\in vec3 frag_pos;
    \\out vec4 out_color;
    \\
    \\void main() {
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

chunks: std.ArrayListUnmanaged(Chunk),
shader: Shader,

const World = @This();
pub fn init() !World {
    var self: World = .{ .shader = try init_chunk_shader(), .chunks = .empty };
    Log.log(.debug, "Generating world...", .{});
    const size = 16;
    for (0..size) |x| {
        for (0..5) |y| {
            for (0..size) |z| {
                const chunk = try self.chunks.addOne(App.gpa());
                try chunk.init(
                    @as(i32, @intCast(x)) - size / 2,
                    @as(i32, @intCast(y)) - 4,
                    @as(i32, @intCast(z)) - size / 2,
                );
            }
        }
    }

    try self.shader.set_vec3("u_ambient", .{ 0.1, 0.1, 0.1 });
    try self.shader.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 2, 1, 1 }));
    try self.shader.set_vec3("u_light_color", .{ 1, 1, 0.9 });

    return self;
}

pub fn deinit(self: *World) void {
    self.shader.deinit();
    for (self.chunks.items) |*c| c.deinit();
    self.chunks.deinit(App.gpa());
}

pub fn draw(self: *World) !void {
    try self.shader.set_vec3("u_view_pos", App.game_state().camera.pos);
    const vp = App.game_state().camera.as_mat();
    try self.shader.set_mat4("u_vp", vp);

    for (self.chunks.items) |*c| {
        try c.draw(&self.shader);
    }
}

fn init_chunk_shader() !Shader {
    var sources: [2]Shader.Source = .{
        .{
            .kind = gl.VERTEX_SHADER,
            .sources = &.{vert},
            .name = "chunk_vert",
        },
        .{
            .kind = gl.FRAGMENT_SHADER,
            .sources = &.{frag},
            .name = "chunk_frag",
        },
    };
    return .init(&sources);
}

pub const Chunk = struct {
    x: i32,
    y: i32,
    z: i32,

    blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockId,

    vao: gl.uint,
    vbo: gl.uint,
    ibo: gl.uint,
    vert_buf_size: usize,
    ind_buf_size: usize,
    index_count: usize,

    const I_OFFSET = CHUNK_SIZE * CHUNK_SIZE;
    const J_OFFSET = CHUNK_SIZE;
    const K_OFFSET = 1;

    pub fn rebuild(self: *Chunk) !void {
        var verts: std.ArrayListUnmanaged(u32) = .empty;
        var inds: std.ArrayListUnmanaged(u32) = .empty;

        for (0..CHUNK_SIZE) |i| {
            for (0..CHUNK_SIZE) |j| {
                for (0..CHUNK_SIZE) |k| {
                    const b = self.blocks[i * I_OFFSET + j * J_OFFSET + k * K_OFFSET];
                    if (b == .air) continue;

                    const top_visible = if (k + 1 == CHUNK_SIZE)
                        true
                    else
                        self.blocks[i * I_OFFSET + j * J_OFFSET + (k + 1) * K_OFFSET] == .air;
                    const bot_visible = if (k == 0)
                        true
                    else
                        self.blocks[i * I_OFFSET + j * J_OFFSET + (k - 1) * K_OFFSET] == .air;
                    const front_visible = if (j + 1 == CHUNK_SIZE)
                        true
                    else
                        self.blocks[i * I_OFFSET + (j + 1) * J_OFFSET + k * K_OFFSET] == .air;
                    const back_visible = if (j == 0)
                        true
                    else
                        self.blocks[i * I_OFFSET + (j - 1) * J_OFFSET + k * K_OFFSET] == .air;
                    const right_visible = if (i + 1 == CHUNK_SIZE)
                        true
                    else
                        self.blocks[(i + 1) * I_OFFSET + j * J_OFFSET + k * K_OFFSET] == .air;
                    const left_visible = if (i == 0)
                        true
                    else
                        self.blocks[(i - 1) * I_OFFSET + j * J_OFFSET + k * K_OFFSET] == .air;

                    if (front_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 1, .front, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 1, .front, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 1, .front, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 1, .front, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                    if (top_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 1, .top, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 0, .top, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 0, .top, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 1, .top, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                    if (back_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 0, .back, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 0, .back, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 0, .back, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 0, .back, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                    if (bot_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 1, .bot, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 0, .bot, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 0, .bot, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 1, .bot, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                    if (left_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 0, .left, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 0, .left, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 1, j + 1, .left, b));
                        try verts.append(App.frame_alloc(), pack(i + 0, k + 0, j + 1, .left, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                    if (right_visible) {
                        const base: u32 = @intCast(verts.items.len);
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 1, .right, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 1, .right, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 1, j + 0, .right, b));
                        try verts.append(App.frame_alloc(), pack(i + 1, k + 0, j + 0, .right, b));
                        try inds.appendSlice(App.frame_alloc(), &.{ base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });
                    }
                }
            }
        }

        const vert_buf_size = verts.items.len * @sizeOf(u32);
        const inds_buf_size = inds.items.len * @sizeOf(u32);
        self.index_count = inds.items.len;
        if (self.vert_buf_size == 0) {
            self.vert_buf_size = vert_buf_size;
            self.ind_buf_size = inds_buf_size;

            try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
            try gl_call(gl.GenBuffers(1, @ptrCast(&self.vbo)));
            try gl_call(gl.GenBuffers(1, @ptrCast(&self.ibo)));
            Log.log(.debug, "{*}: Allocated {d} bytes", .{ self, self.vert_buf_size });
            Log.log(.debug, "{*}: Allocated {d} bytes", .{ self, self.ind_buf_size });

            try gl_call(gl.BindVertexArray(self.vao));
            try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo));
            try gl_call(gl.BufferData(
                gl.ARRAY_BUFFER,
                @intCast(vert_buf_size),
                @ptrCast(verts.items),
                gl.STATIC_DRAW,
            ));
            try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ibo));
            try gl_call(gl.BufferData(
                gl.ELEMENT_ARRAY_BUFFER,
                @intCast(inds_buf_size),
                @ptrCast(inds.items),
                gl.STATIC_DRAW,
            ));
            try gl_call(gl.VertexAttribIPointer(0, 1, gl.UNSIGNED_INT, @sizeOf(u32), 0));
            try gl_call(gl.EnableVertexAttribArray(0));

            return;
        }

        std.debug.panic("TODO!", .{});
    }

    const Face = enum(u8) { front, back, right, left, top, bot };
    fn pack(x: usize, y: usize, z: usize, face: Face, block: BlockId) u32 {
        var res: u32 = 0;

        res |= @as(u32, @intFromEnum(face)) << 29;
        res |= @as(u32, @intCast(x)) << 24;
        res |= @as(u32, @intCast(y)) << 16;
        res |= @as(u32, @intCast(z)) << 8;
        res |= @as(u32, @intFromEnum(block));

        return res;
    }

    pub fn draw(self: *Chunk, shader: *Shader) !void {
        try shader.set("u_chunk_coord", .{ self.x, self.y, self.z }, "3i");

        try gl_call(gl.BindVertexArray(self.vao));
        try gl_call(gl.DrawElements(gl.TRIANGLES, @intCast(self.index_count), gl.UNSIGNED_INT, 0));
        try gl_call(gl.BindVertexArray(0));
    }

    pub fn init(self: *Chunk, x: i32, y: i32, z: i32) !void {
        self.* = std.mem.zeroes(Chunk);
        self.x = x;
        self.y = y;
        self.z = z;

        self.dummy_generate();

        try self.rebuild();
    }

    fn dummy_generate(self: *Chunk) void {
        if (self.y > 0) {
            @memset(&self.blocks, .air);
            return;
        } else if (self.y < 0) {
            @memset(&self.blocks, .stone);
            return;
        }

        const scale = std.math.pi / 16.0;
        for (0..CHUNK_SIZE) |i| {
            for (0..CHUNK_SIZE) |j| {
                const x: f32 = @floatFromInt(self.x * CHUNK_SIZE + @as(i32, @intCast(i)));
                const z: f32 = @floatFromInt(self.z * CHUNK_SIZE + @as(i32, @intCast(j)));
                const top: usize = @intFromFloat((@sin(x * scale) + @cos(z * scale)) * 3 + 8);

                const offset = i * I_OFFSET + j * J_OFFSET;
                self.blocks[offset + top * K_OFFSET] = .grass;
                const dirt_start = if (top >= 4) top - 4 else 0;
                for (top + 1..CHUNK_SIZE) |k| self.blocks[offset + k * K_OFFSET] = .air;
                for (dirt_start..top) |k| self.blocks[offset + k * K_OFFSET] = .dirt;
                for (0..dirt_start) |k| self.blocks[offset + k * K_OFFSET] = .stone;
            }
        }
    }

    pub fn deinit(self: *Chunk) void {
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        gl.DeleteBuffers(1, @ptrCast(&self.ibo));
        gl.DeleteBuffers(1, @ptrCast(&self.vbo));
    }
};
