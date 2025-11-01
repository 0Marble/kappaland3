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
    \\layout (std140, binding = 1) buffer Chunk {
    \\  ivec3 chunk_coords[];
    \\};
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
    \\uvec3 dummy_pos() {
    \\  uint i = gl_VertexID / 4;
    \\  uint x = i / 256;
    \\  uint y = i % 16;
    \\  uint z = (i / 16) % 16;
    \\  uvec3 quad[4] = {uvec3(0,1,1), uvec3(0,1,0), uvec3(1,1,0), uvec3(1,1,1)};
    \\  return quad[gl_VertexID % 4] + uvec3(x,y,z);
    \\}
    \\
    \\void main() {
    \\  uint n = (vert_data & uint(0xE0000000)) >> 29;
    \\  uint x = (vert_data & uint(0x1F000000)) >> 24;
    \\  uint y = (vert_data & uint(0x001F0000)) >> 16;
    \\  uint z = (vert_data & uint(0x00001F00)) >> 8;
    \\  uint t = (vert_data & uint(0x000000FF)) >> 0;
    \\  frag_pos = vec3(x,y,z) + 16.0 * vec3(chunk_coords[gl_DrawID]);
    \\  if (gl_DrawID >= 498) frag_color = vec3(1,0,1);
    \\  else frag_color = vec3(x,y,z)/16;
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

chunks: []Chunk,
shader: Shader,

vao: gl.uint,
verts_vbo: gl.uint,
verts_ibo: gl.uint,
chunk_coords_ssbo: gl.uint,
counts: []i32,
index_position_offsets: []usize,
index_value_offsets: []i32,

const World = @This();
pub fn init() !World {
    var self: World = undefined;
    try self.init_shader();
    try self.init_chunks();
    try self.init_buffers();

    return self;
}

fn init_buffers(self: *World) !void {
    self.counts = try App.gpa().alloc(i32, self.chunks.len);
    self.index_position_offsets = try App.gpa().alloc(usize, self.chunks.len);
    self.index_value_offsets = try App.gpa().alloc(i32, self.chunks.len);
    var total_vertex_count: i32 = 0;
    var total_index_count: usize = 0;
    for (0..self.chunks.len) |i| {
        self.counts[i] = @intCast(self.chunks[i].inds.items.len);
        self.index_value_offsets[i] = total_vertex_count;
        total_vertex_count += @intCast(self.chunks[i].verts.items.len);
        self.index_position_offsets[i] = total_index_count * @sizeOf(u32);
        total_index_count += self.chunks[i].inds.items.len;
    }

    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.verts_vbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.verts_ibo)));

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.verts_vbo));
    try gl_call(gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(total_vertex_count * @sizeOf(u32)),
        null,
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.verts_ibo));
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(total_index_count * @sizeOf(u32)),
        null,
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.EnableVertexAttribArray(0));
    try gl_call(gl.VertexAttribIPointer(0, 1, gl.UNSIGNED_INT, @sizeOf(u32), 0));

    var vert_offset: usize = 0;
    var inds_offset: usize = 0;
    for (0..self.chunks.len) |i| {
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            @intCast(vert_offset * @sizeOf(u32)),
            @intCast(self.chunks[i].verts.items.len * @sizeOf(u32)),
            @ptrCast(self.chunks[i].verts.items),
        ));
        vert_offset += self.chunks[i].verts.items.len;
        try gl_call(gl.BufferSubData(
            gl.ELEMENT_ARRAY_BUFFER,
            @intCast(inds_offset * @sizeOf(u32)),
            @intCast(self.chunks[i].inds.items.len * @sizeOf(u32)),
            @ptrCast(self.chunks[i].inds.items),
        ));
        inds_offset += self.chunks[i].inds.items.len;
    }

    var chunk_coords = try App.frame_alloc().alloc(i32, 4 * self.chunks.len);
    for (0..self.chunks.len) |i| {
        chunk_coords[4 * i + 0] = self.chunks[i].x;
        chunk_coords[4 * i + 1] = self.chunks[i].y;
        chunk_coords[4 * i + 2] = self.chunks[i].z;
        chunk_coords[4 * i + 3] = 0;
    }

    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_coords_ssbo)));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(chunk_coords.len * @sizeOf(i32)),
        @ptrCast(chunk_coords),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, self.chunk_coords_ssbo));

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    for (0..self.chunks.len) |i| {
        Log.log(.debug, "{*}: Chunk[{d}] {*}:", .{ self, i, &self.chunks[i] });
        Log.log(.debug, "\tPrimitive count: {d}", .{self.counts[i]});
        Log.log(.debug, "\tIndex position: {d}", .{self.index_position_offsets[i]});
        Log.log(.debug, "\tIndex offset: {d}", .{self.index_value_offsets[i]});
        Log.log(.debug, "\tChunk coordinates: {}", .{.{
            chunk_coords[4 * i + 0],
            chunk_coords[4 * i + 1],
            chunk_coords[4 * i + 2],
        }});
    }
}

fn init_chunks(self: *World) !void {
    Log.log(.debug, "Generating world...", .{});
    const dim = 8;
    const height = 8;
    const chunk_count = dim * dim * height;
    self.chunks = try App.gpa().alloc(Chunk, chunk_count);
    for (0..dim) |i| {
        for (0..dim) |j| {
            for (0..height) |k| {
                const idx = i * dim * height + j * height + k;
                const x: i32 = @intCast(i);
                const y: i32 = @intCast(k);
                const z: i32 = @intCast(j);
                try self.chunks[idx].init(x - dim / 2, y - height + 1, z - dim / 2);
            }
        }
    }
    Log.log(.debug, "Generated world: {d} chunks", .{chunk_count});
}

pub fn deinit(self: *World) void {
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_coords_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.verts_vbo));
    gl.DeleteBuffers(1, @ptrCast(&self.verts_ibo));
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));

    self.shader.deinit();
    for (self.chunks) |*c| c.deinit();
    App.gpa().free(self.chunks);
    App.gpa().free(self.index_position_offsets);
    App.gpa().free(self.index_value_offsets);
    App.gpa().free(self.counts);
}

pub fn draw(self: *World) !void {
    try self.shader.set_vec3("u_view_pos", App.game_state().camera.pos);
    const vp = App.game_state().camera.as_mat();
    try self.shader.set_mat4("u_vp", vp);

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.MultiDrawElementsBaseVertex(
        gl.TRIANGLES,
        self.counts.ptr,
        gl.UNSIGNED_INT,
        self.index_position_offsets.ptr,
        @intCast(self.chunks.len),
        self.index_value_offsets.ptr,
    ));
    try gl_call(gl.BindVertexArray(0));
}

fn init_shader(self: *World) !void {
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

    self.shader = try .init(&sources);
    try self.shader.set_vec3("u_ambient", .{ 0.1, 0.1, 0.1 });
    try self.shader.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 2, 1, 1 }));
    try self.shader.set_vec3("u_light_color", .{ 1, 1, 0.9 });
}

pub const Chunk = struct {
    x: i32,
    y: i32,
    z: i32,

    blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockId,
    verts: std.ArrayListUnmanaged(u32),
    inds: std.ArrayListUnmanaged(u32),

    const I_OFFSET = CHUNK_SIZE * CHUNK_SIZE;
    const J_OFFSET = CHUNK_SIZE;
    const K_OFFSET = 1;

    pub fn build_mesh(self: *Chunk) !void {
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

                    if (top_visible) {
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 1, .top, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 0, .top, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 0, .top, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 1, .top, b));
                    }
                    if (front_visible) {
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 1, .front, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 1, .front, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 1, .front, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 1, .front, b));
                    }
                    if (back_visible) {
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 0, .back, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 0, .back, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 0, .back, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 0, .back, b));
                    }
                    if (bot_visible) {
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 1, .bot, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 0, .bot, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 0, .bot, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 1, .bot, b));
                    }
                    if (left_visible) {
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 0, .left, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 0, .left, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 1, j + 1, .left, b));
                        try self.verts.append(App.gpa(), pack(i + 0, k + 0, j + 1, .left, b));
                    }
                    if (right_visible) {
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 1, .right, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 1, .right, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 1, j + 0, .right, b));
                        try self.verts.append(App.gpa(), pack(i + 1, k + 0, j + 0, .right, b));
                    }
                }
            }
        }

        for (0..self.verts.items.len / 4) |i| {
            const j: u32 = @as(u32, @intCast(i)) * 4;
            try self.inds.appendSlice(App.gpa(), &.{ j + 0, j + 1, j + 2, j + 0, j + 2, j + 3 });
        }
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
        self.* = .{
            .verts = .empty,
            .inds = .empty,
            .x = x,
            .y = y,
            .z = z,
            .blocks = undefined,
        };
        self.dummy_generate();
        try self.build_mesh();

        Log.log(.debug, "{*}: generated at {}, verts: {d}, inds: {d}", .{
            self,
            .{ self.x, self.y, self.z },
            self.verts.items.len,
            self.inds.items.len,
        });
    }

    fn dummy_generate(self: *Chunk) void {
        @memset(&self.blocks, .air);
        if (self.y > 0) {
            return;
        } else if (self.y < 0) {
            @memset(self.blocks[0 .. CHUNK_SIZE * CHUNK_SIZE * 4], .stone);
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
        self.verts.deinit(App.gpa());
        self.inds.deinit(App.gpa());
    }
};
