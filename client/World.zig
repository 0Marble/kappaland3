const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const gl_call = @import("util.zig").gl_call;
const Shader = @import("Shader.zig");
const App = @import("App.zig");
const Options = @import("ClientOptions");

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
    \\layout (location = 0) in uint vert_data;    // xxxxyyyy|zzzz?nnn|????????|tttttttt
    \\                                            // per instance
    \\layout (std140, binding = 1) buffer Chunk {
    \\  ivec3 chunk_coords[];
    \\};
++ (if (Options.chunk_debug_buffer)
    \\layout (std430, binding = 2) buffer Debug { 
    \\  uint debug_vertex_ids[];
    \\};
    \\
else
    "") ++
    \\uniform mat4 u_vp;
    \\
    \\out vec3 frag_norm;
    \\out vec3 frag_color;
    \\out vec3 frag_pos;
    \\
    \\vec3 normals[6] = {
    \\  vec3(0, 0, 1),  // front
    \\  vec3(0, 0, -1), // back
    \\  vec3(1, 0, 0),  // right
    \\  vec3(-1, 0, 0), // left
    \\  vec3(0, 1, 0),  // top
    \\  vec3(0, -1, 0), // bottom
    \\};
    \\vec3 colors[4] = {
    \\  vec3(0, 0, 0),
    \\  vec3(0.2,0.2,0.2),
    \\  vec3(0.4,0.2,0),
    \\  vec3(0.1,0.4,0.1),
    \\};
    \\vec3 faces[6][4] = {
    \\  {vec3(0,0,1),vec3(0,1,1),vec3(1,1,1),vec3(1,0,1)}, 
    \\  {vec3(1,0,0),vec3(1,1,0),vec3(0,1,0),vec3(0,0,0)}, 
    \\  {vec3(1,0,1),vec3(1,1,1),vec3(1,1,0),vec3(1,0,0)}, 
    \\  {vec3(0,0,0),vec3(0,1,0),vec3(0,1,1),vec3(0,0,1)}, 
    \\  {vec3(0,1,1),vec3(0,1,0),vec3(1,1,0),vec3(1,1,1)}, 
    \\  {vec3(1,0,1),vec3(1,0,0),vec3(0,0,0),vec3(0,0,1)},
    \\};
    \\
    \\void main() {
    \\  uint x = (vert_data & uint(0xF0000000)) >> 28;
    \\  uint y = (vert_data & uint(0x0F000000)) >> 24;
    \\  uint z = (vert_data & uint(0x00F00000)) >> 20;
    \\  uint n = (vert_data & uint(0x000F0000)) >> 16;
    \\  uint p = (vert_data & uint(0x0000FF00)) >> 8;
    \\  uint t = (vert_data & uint(0x000000FF)) >> 0;
    \\  frag_pos = vec3(x,y,z) + faces[n][gl_VertexID] + 16 * vec3(chunk_coords[gl_DrawID]);
    \\  frag_color = vec3(x,y,z)/16;
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
ibo: gl.uint,
face_data_buffer: gl.uint,
chunk_coords_ssbo: gl.uint,
indirect_buffer: gl.uint,
debug_buffer: if (Options.chunk_debug_buffer) gl.uint else void,

const World = @This();
pub fn init() !World {
    var self: World = undefined;
    try self.init_shader();
    try self.init_chunks();
    try self.init_buffers();

    return self;
}

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

fn init_buffers(self: *World) !void {
    const indirect = try App.frame_alloc().alloc(Indirect, self.chunks.len);
    const chunk_coords = try App.frame_alloc().alloc(i32, 4 * self.chunks.len);
    var total_face_count: usize = 0;

    for (0..self.chunks.len) |i| {
        const chunk = &self.chunks[i];
        chunk_coords[4 * i + 0] = chunk.x;
        chunk_coords[4 * i + 1] = chunk.y;
        chunk_coords[4 * i + 2] = chunk.z;
        chunk_coords[4 * i + 3] = 0;
        indirect[i] = .{
            .count = 6,
            .instance_count = @intCast(chunk.face_data.items.len),
            .base_instance = @intCast(total_face_count),
            .first_index = 0,
            .base_vertex = 0,
        };
        total_face_count += self.chunks[i].face_data.items.len;

        Log.log(.debug, "{*}: Chunk[{d}] {*}:", .{ self, i, &self.chunks[i] });
        Log.log(.debug, "\tPrimitive count: {d}", .{indirect[i].count});
        Log.log(.debug, "\tInstance count: {d}", .{indirect[i].instance_count});
        Log.log(.debug, "\tIndex start: {d}", .{indirect[i].first_index});
        Log.log(.debug, "\tIndex offset: +{d}", .{indirect[i].base_vertex});
        Log.log(.debug, "\tBase instance: {d}", .{indirect[i].base_instance});
        Log.log(.debug, "\tChunk coordinates: {}", .{.{
            chunk_coords[4 * i + 0],
            chunk_coords[4 * i + 1],
            chunk_coords[4 * i + 2],
        }});
    }

    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.face_data_buffer)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_coords_ssbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buffer)));
    if (Options.chunk_debug_buffer) {
        try gl_call(gl.GenBuffers(1, @ptrCast(&self.debug_buffer)));
    }

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.face_data_buffer));
    try gl_call(gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(total_face_count * @sizeOf(u32)),
        null,
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ibo));
    const inds = [_]u8{ 0, 1, 2, 0, 2, 3 };
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(6 * @sizeOf(u8)),
        &inds,
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.EnableVertexAttribArray(0));
    try gl_call(gl.VertexAttribIPointer(0, 1, gl.UNSIGNED_INT, @sizeOf(u32), 0));
    try gl_call(gl.VertexAttribDivisor(0, 1));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(chunk_coords.len * @sizeOf(i32)),
        @ptrCast(chunk_coords),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, self.chunk_coords_ssbo));

    if (Options.chunk_debug_buffer) {
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.debug_buffer));
        try gl_call(gl.BufferStorage(
            gl.SHADER_STORAGE_BUFFER,
            DEBUG_SIZE * @sizeOf(u32),
            null,
            gl.MAP_READ_BIT | gl.MAP_COHERENT_BIT | gl.MAP_PERSISTENT_BIT,
        ));
        try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, self.debug_buffer));
    }

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        @intCast(indirect.len * @sizeOf(Indirect)),
        @ptrCast(indirect),
        gl.STATIC_DRAW,
    ));

    var vert_offset: usize = 0;
    for (0..self.chunks.len) |i| {
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            @intCast(vert_offset * @sizeOf(u32)),
            @intCast(self.chunks[i].face_data.items.len * @sizeOf(u32)),
            @ptrCast(self.chunks[i].face_data.items),
        ));
        vert_offset += self.chunks[i].face_data.items.len;
    }

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
}

const DIM = 8;
const HEIGHT = 2;
const DEBUG_SIZE = DIM * DIM * HEIGHT * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 6;
fn init_chunks(self: *World) !void {
    Log.log(.debug, "Generating world...", .{});
    const chunk_count = DIM * DIM * HEIGHT;
    self.chunks = try App.gpa().alloc(Chunk, chunk_count);
    for (0..DIM) |i| {
        for (0..DIM) |j| {
            for (0..HEIGHT) |k| {
                const idx = i * DIM * HEIGHT + j * HEIGHT + k;
                const x: i32 = @intCast(i);
                const y: i32 = @intCast(k);
                const z: i32 = @intCast(j);
                try self.chunks[idx].init(x - DIM / 2, y - HEIGHT + 1, z - DIM / 2);
            }
        }
    }
    Log.log(.debug, "Generated world: {d} chunks", .{chunk_count});
}

pub fn deinit(self: *World) void {
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_coords_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.face_data_buffer));
    gl.DeleteBuffers(1, @ptrCast(&self.ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.indirect_buffer));
    if (Options.chunk_debug_buffer) {
        gl.DeleteBuffers(1, @ptrCast(&self.debug_buffer));
    }
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));

    self.shader.deinit();
    for (self.chunks) |*c| c.deinit();
    App.gpa().free(self.chunks);
}

pub fn draw(self: *World) !void {
    try self.shader.set_vec3("u_view_pos", App.game_state().camera.pos);
    const vp = App.game_state().camera.as_mat();
    try self.shader.set_mat4("u_vp", vp);

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        gl.UNSIGNED_BYTE,
        0,
        @intCast(self.chunks.len),
        0,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
    try gl_call(gl.BindVertexArray(0));

    if (Options.chunk_debug_buffer and App.current_frame() == 0) {
        try gl_call(gl.Finish());
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.debug_buffer));
        const ptr: [*]const u32 = @ptrCast(@alignCast((try gl_call(gl.MapBuffer(
            gl.SHADER_STORAGE_BUFFER,
            gl.READ_ONLY,
        ))).?));
        var debug = std.mem.zeroes([DEBUG_SIZE]u32);
        @memcpy(&debug, ptr);
        _ = try gl_call(gl.UnmapBuffer(gl.SHADER_STORAGE_BUFFER));
        Log.log(.debug, "{any}", .{debug[0..100]});
    }
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
    face_data: std.ArrayListUnmanaged(u32),
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

                    if (k + 1 == CHUNK_SIZE or self.blocks[i * I_OFFSET + j * J_OFFSET + (k + 1) * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .top, b));
                    }
                    if (j + 1 == CHUNK_SIZE or self.blocks[i * I_OFFSET + (j + 1) * J_OFFSET + k * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .front, b));
                    }
                    if (i + 1 == CHUNK_SIZE or self.blocks[(i + 1) * I_OFFSET + j * J_OFFSET + k * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .right, b));
                    }
                    if (k == 0 or self.blocks[i * I_OFFSET + j * J_OFFSET + (k - 1) * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .bot, b));
                    }
                    if (j == 0 or self.blocks[i * I_OFFSET + (j - 1) * J_OFFSET + k * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .back, b));
                    }
                    if (i == 0 or self.blocks[(i - 1) * I_OFFSET + j * J_OFFSET + k * K_OFFSET] == .air) {
                        try self.face_data.append(App.gpa(), pack(i, k, j, .left, b));
                    }
                }
            }
        }
    }

    const Face = enum(u8) { front, back, right, left, top, bot };
    fn pack(x: usize, y: usize, z: usize, face: Face, block: BlockId) u32 {
        var res: u32 = 0;

        res |= @as(u32, @intCast(x)) << 28;
        res |= @as(u32, @intCast(y)) << 24;
        res |= @as(u32, @intCast(z)) << 20;
        res |= @as(u32, @intFromEnum(face)) << 16;

        res |= @as(u32, @intCast(0xC3)) << 8;
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
            .face_data = .empty,
            .inds = .empty,
            .x = x,
            .y = y,
            .z = z,
            .blocks = undefined,
        };
        self.dummy_generate();
        try self.build_mesh();
        // const b: BlockId = if (@rem(x + y + z, 2) == 0) .dirt else .stone;
        // try self.face_data.append(App.gpa(), pack(0, 0, 0, .top, b));
    }

    fn dummy_generate(self: *Chunk) void {
        @memset(&self.blocks, .air);
        if (self.y > 0) {
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
        self.face_data.deinit(App.gpa());
        self.inds.deinit(App.gpa());
    }
};
