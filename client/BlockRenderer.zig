const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const BlockModel = @import("Block");
const std = @import("std");
const Options = @import("ClientOptions");
const App = @import("App.zig");
const GpuAlloc = @import("GpuAlloc.zig");
const gl = @import("gl");
const zm = @import("zm");
const Shader = @import("Shader.zig");
const util = @import("util.zig");
const Log = @import("libmine").Log;
const gl_call = util.gl_call;
const Renderer = @import("Renderer.zig");

const CHUNK_SIZE = World.CHUNK_SIZE;
const EXPECTED_BUFFER_SIZE = 16 * 1024 * 1024;
const EXPECTED_LOADED_CHUNKS_COUNT = World.DIM * World.DIM * World.HEIGHT;
const MINIMAL_MESH_SIZE = 1024;
const VERT_DATA_LOCATION = 0;
const CHUNK_DATA_BINDING = 1;
const BLOCK_DATA_BINDING = 3;
const VERT_DATA_BINDING = 4;
const BLOCK_FACE_COUNT = BlockModel.faces.len;
const VERTS_PER_FACE = BlockModel.faces[0].len;
const N_OFFSET = VERTS_PER_FACE * CHUNK_SIZE * CHUNK_SIZE;
const W_OFFSET = VERTS_PER_FACE * CHUNK_SIZE;
const H_OFFSET = VERTS_PER_FACE;
const P_OFFSET = 1;

const VERT =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define BLOCK_FACE_COUNT {d}\n", .{BLOCK_FACE_COUNT}) ++
    \\
++ std.fmt.comptimePrint("#define VERTS_PER_FACE {d}\n", .{VERTS_PER_FACE}) ++
    \\
++ std.fmt.comptimePrint("#define VERT_DATA_LOCATION {d}\n", .{VERT_DATA_LOCATION}) ++
    \\
++ std.fmt.comptimePrint("#define CHUNK_DATA_LOCATION {d}\n", .{CHUNK_DATA_BINDING}) ++
    \\
++ std.fmt.comptimePrint("#define BLOCK_DATA_LOCATION {d}\n", .{BLOCK_DATA_BINDING}) ++
    \\
++ std.fmt.comptimePrint("#define CHUNK_SIZE {d}\n", .{CHUNK_SIZE}) ++
    \\
++ std.fmt.comptimePrint("#define N_OFFSET {d}\n", .{N_OFFSET}) ++
    \\
++ std.fmt.comptimePrint("#define W_OFFSET {d}\n", .{W_OFFSET}) ++
    \\
++ std.fmt.comptimePrint("#define H_OFFSET {d}\n", .{H_OFFSET}) ++
    \\
++ std.fmt.comptimePrint("#define P_OFFSET {d}\n", .{P_OFFSET}) ++
    \\
    \\layout (location = VERT_DATA_LOCATION) in uint vert_data;    // xxxxyyyy|zzzz?nnn|wwwwhhhh|tttttttt
    \\                                            // per instance
    \\uniform mat4 u_vp;
    \\
    \\out vec3 frag_norm;
    \\out vec3 frag_color;
    \\out vec3 frag_pos;
    \\layout (std430, binding = CHUNK_DATA_LOCATION) buffer Chunk {
    \\  ivec3 chunk_coords[];
    \\};
    \\
    \\layout(std140, binding = BLOCK_DATA_LOCATION) uniform Block {
    \\  vec3 normals[BLOCK_FACE_COUNT];
    \\  vec3 faces[BLOCK_FACE_COUNT * VERTS_PER_FACE * CHUNK_SIZE * CHUNK_SIZE];
    \\};
    \\vec3 colors[4] = {vec3(0,0,0),vec3(0.2,0.2,0.2),vec3(0.6,0.4,0.2),vec3(0.2,0.7,0.3)};
    \\
    \\void main() {
    \\  uint x = (vert_data & uint(0xF0000000)) >> 28;
    \\  uint y = (vert_data & uint(0x0F000000)) >> 24;
    \\  uint z = (vert_data & uint(0x00F00000)) >> 20;
    \\  uint n = (vert_data & uint(0x000F0000)) >> 16;
    \\  uint w = (vert_data & uint(0x0000F000)) >> 12;
    \\  uint h = (vert_data & uint(0x00000F00)) >> 8;
    \\  uint t = (vert_data & uint(0x000000FF));
    \\
    \\  uint p = gl_VertexID;
    \\  uint face = w * W_OFFSET + h * H_OFFSET + p * P_OFFSET + n * N_OFFSET;
    \\
    \\  frag_pos = vec3(x, y, z) + faces[face] + 16 * vec3(chunk_coords[gl_DrawID]);
    \\  frag_color = vec3(x, y, z) / 16.0;
    \\  frag_norm = normals[n];
    \\  gl_Position = u_vp * vec4(frag_pos, 1);
    \\}
;
const FRAG =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define BASE_COLOR_ATTACHMENT {d}\n", .{Renderer.BASE_COLOR_ATTACHMENT}) ++
    \\
++ std.fmt.comptimePrint("#define POS_ATTACHMENT {d}\n", .{Renderer.POS_ATTACHMENT}) ++
    \\
++ std.fmt.comptimePrint("#define NORMAL_ATTACHMENT {d}\n", .{Renderer.NORMAL_ATTACHMENT}) ++
    \\
++ std.fmt.comptimePrint("#define BLOCK_COORDS_ATTACHMENT {d}\n", .{Renderer.BLOCK_COORDS_ATTACHMENT}) ++
    \\
    \\in vec3 frag_color;
    \\in vec3 frag_norm;
    \\in vec3 frag_pos;
    \\
    \\layout(location = BASE_COLOR_ATTACHMENT) out vec4 out_color;
    \\layout(location = POS_ATTACHMENT) out vec4 out_pos;
    \\layout(location = NORMAL_ATTACHMENT) out vec4 out_norm;
    \\layout(location = BLOCK_COORDS_ATTACHMENT) out ivec4 out_coords;
    \\
    \\void main() {
    \\  out_color = vec4(frag_color, 1);
    \\  out_pos = vec4(frag_pos, 0);
    \\  out_norm = vec4(frag_norm, 0);
    \\  out_coords = ivec4(0,0,0,0);
    \\}
;

shader: Shader,
faces: GpuAlloc,
indirect_buffer: gl.uint,
chunk_coords_ssbo: gl.uint,
allocated_chunks_count: usize,
vao: gl.uint,
block_model_ibo: gl.uint,
block_model_ubo: gl.uint,

meshes_changed: bool,
meshes: std.AutoArrayHashMapUnmanaged(World.ChunkCoords, *ChunkMesh),
freelist: std.ArrayListUnmanaged(*ChunkMesh),
triangle_count: usize,

const Self = @This();

pub fn init(self: *Self) !void {
    self.meshes_changed = false;
    self.meshes = .empty;
    self.freelist = .empty;
    self.triangle_count = 0;

    self.faces = try .init(App.gpa(), EXPECTED_BUFFER_SIZE, gl.STREAM_DRAW);
    try self.init_buffers();
    try self.init_shader();
}

pub fn deinit(self: *Self) void {
    for (self.freelist.items) |mesh| mesh.deinit();
    for (self.meshes.values()) |mesh| mesh.deinit();
    self.meshes.deinit(App.gpa());
    self.freelist.deinit(App.gpa());

    self.faces.deinit();
    gl.DeleteBuffers(1, @ptrCast(&self.block_model_ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.block_model_ubo));
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_coords_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.indirect_buffer));
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));

    self.shader.deinit();
}

pub fn draw(self: *Self) !void {
    try self.regenerate_indirect();

    try self.shader.set_vec3("u_view_pos", App.game_state().camera.pos);
    const vp = App.game_state().camera.as_mat();
    try self.shader.set_mat4("u_vp", vp);

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        @field(gl, BlockModel.index_type),
        0,
        @intCast(self.meshes.count()),
        0,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
    try gl_call(gl.BindVertexArray(0));
}

pub fn upload_chunk(self: *Self, chunk: *Chunk) !void {
    if (self.meshes.get(chunk.coords)) |existing| {
        Log.log(.warn, "TODO: updating chunks", .{});
        _ = existing;
    } else {
        const mesh = if (self.freelist.pop()) |mesh|
            mesh
        else
            try ChunkMesh.create();

        mesh.init(chunk);
        try mesh.build();
        try self.update_mesh(mesh);

        if (try self.meshes.fetchPut(App.gpa(), chunk.coords, mesh)) |_| {
            Log.log(.warn, "{*}: Multiple meshes for chunk at {}", .{ self, chunk.coords });
        }
    }
    self.meshes_changed = true;
}

const raw_faces: []const u8 = blk: {
    @setEvalBranchQuota(std.math.maxInt(u32));
    var normals_data = std.mem.zeroes([4 * BLOCK_FACE_COUNT]u32);
    for (BlockModel.normals, 0..) |normal, i| {
        normals_data[1 + 4 * i + 0] = @bitCast(@as(f32, normal[0]));
        normals_data[1 + 4 * i + 1] = @bitCast(@as(f32, normal[1]));
        normals_data[1 + 4 * i + 2] = @bitCast(@as(f32, normal[2]));
    }
    const size = 4 * BLOCK_FACE_COUNT * VERTS_PER_FACE * World.CHUNK_SIZE * World.CHUNK_SIZE;
    var faces_data = std.mem.zeroes([size]u32);
    for (BlockModel.faces, 0..) |face, n| {
        for (0..World.CHUNK_SIZE) |w| {
            for (0..World.CHUNK_SIZE) |h| {
                for (face, 0..) |vertex, p| {
                    const idx = n * N_OFFSET + w * W_OFFSET + h * H_OFFSET + p * P_OFFSET;
                    const vec: zm.Vec3f = vertex;
                    var scale = World.BlockCoords{ .x = 1, .y = 1, .z = 1 };
                    @field(scale, BlockModel.scale[n][0..1]) = w + 1;
                    @field(scale, BlockModel.scale[n][1..2]) = h + 1;
                    faces_data[4 * idx + 0] = @bitCast(vec[0] * scale.x);
                    faces_data[4 * idx + 1] = @bitCast(vec[1] * scale.y);
                    faces_data[4 * idx + 2] = @bitCast(vec[2] * scale.z);
                }
            }
        }
    }

    break :blk @ptrCast(&(normals_data ++ faces_data));
};

fn init_buffers(self: *Self) !void {
    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_model_ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_model_ubo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buffer)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_coords_ssbo)));

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        @intCast(EXPECTED_LOADED_CHUNKS_COUNT * @sizeOf(Indirect)),
        null,
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(EXPECTED_LOADED_CHUNKS_COUNT * @sizeOf(u32) * 4),
        null,
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    try gl_call(gl.BindVertexArray(self.vao));

    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.block_model_ibo));
    const inds: []const u8 = &BlockModel.indices;
    try gl_call(gl.BufferStorage(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(6 * @sizeOf(u8)),
        inds.ptr,
        0,
    ));

    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, self.block_model_ubo));
    try gl_call(gl.BufferStorage(
        gl.UNIFORM_BUFFER,
        @intCast(raw_faces.len),
        raw_faces.ptr,
        0,
    ));
    try gl_call(gl.BindBufferBase(gl.UNIFORM_BUFFER, BLOCK_DATA_BINDING, self.block_model_ubo));

    try gl_call(gl.BindVertexBuffer(VERT_DATA_BINDING, self.faces.buffer, 0, @sizeOf(u32)));
    try gl_call(gl.EnableVertexAttribArray(VERT_DATA_LOCATION));
    try gl_call(gl.VertexAttribIFormat(VERT_DATA_LOCATION, 1, gl.UNSIGNED_INT, 0));
    try gl_call(gl.VertexAttribBinding(VERT_DATA_LOCATION, VERT_DATA_BINDING));
    try gl_call(gl.VertexBindingDivisor(VERT_DATA_BINDING, 1));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, CHUNK_DATA_BINDING, self.chunk_coords_ssbo));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
}

fn init_shader(self: *Self) !void {
    var sources: [2]Shader.Source = .{
        .{
            .kind = gl.VERTEX_SHADER,
            .sources = &.{VERT},
            .name = "chunk_vert",
        },
        .{
            .kind = gl.FRAGMENT_SHADER,
            .sources = &.{FRAG},
            .name = "chunk_frag",
        },
    };

    self.shader = try .init(&sources);
}

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

fn regenerate_indirect(self: *Self) !void {
    if (!self.meshes_changed) return;
    self.meshes_changed = false;

    const count = self.meshes.count();
    const indirect = try App.frame_alloc().alloc(Indirect, count);
    const coords = try App.frame_alloc().alloc(i32, 4 * count);
    self.triangle_count = 0;
    for (self.meshes.values(), 0..) |mesh, i| {
        const range = self.faces.get_range(mesh.handle).?;
        indirect[i] = Indirect{
            .count = 6,
            .instance_count = @intCast(mesh.faces.items.len),
            .base_instance = @intCast(@divExact(range.offset, 4)),
            .base_vertex = 0,
            .first_index = 0,
        };
        coords[4 * i + 0] = mesh.chunk.?.coords.x;
        coords[4 * i + 1] = mesh.chunk.?.coords.y;
        coords[4 * i + 2] = mesh.chunk.?.coords.z;
        self.triangle_count += 3 * mesh.faces.items.len;
    }

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));

    if (self.allocated_chunks_count < count) {
        self.allocated_chunks_count = count * 2;
        try gl_call(gl.BufferData(
            gl.SHADER_STORAGE_BUFFER,
            @intCast(self.allocated_chunks_count * @sizeOf(i32) * 4),
            null,
            gl.STREAM_DRAW,
        ));
        try gl_call(gl.BufferData(
            gl.DRAW_INDIRECT_BUFFER,
            @intCast(self.allocated_chunks_count * @sizeOf(Indirect)),
            null,
            gl.STREAM_DRAW,
        ));
    }

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BufferSubData(
        gl.SHADER_STORAGE_BUFFER,
        0,
        @intCast(coords.len * @sizeOf(i32)),
        @ptrCast(coords),
    ));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    try gl_call(gl.BufferSubData(
        gl.DRAW_INDIRECT_BUFFER,
        0,
        @intCast(indirect.len * @sizeOf(Indirect)),
        @ptrCast(indirect),
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindVertexBuffer(VERT_DATA_BINDING, self.faces.buffer, 0, @sizeOf(u32)));
    try gl_call(gl.BindVertexArray(0));
}

const ChunkMesh = struct {
    const X_OFFSET = Chunk.X_OFFSET;
    const Y_OFFSET = Chunk.Y_OFFSET;
    const Z_OFFSET = Chunk.Z_OFFSET;

    chunk: ?*Chunk,
    faces: std.ArrayListUnmanaged(u32),
    handle: GpuAlloc.Handle,

    fn create() !*ChunkMesh {
        const self = try App.gpa().create(ChunkMesh);
        self.chunk = null;
        self.faces = .empty;
        self.handle = .invalid;
        return self;
    }
    fn init(self: *ChunkMesh, chunk: *Chunk) void {
        self.chunk = chunk;
    }

    fn clear(self: *ChunkMesh) void {
        self.faces.clearRetainingCapacity();
    }

    fn deinit(self: *ChunkMesh) void {
        self.faces.deinit(App.gpa());
        App.gpa().destroy(self);
    }

    fn build(self: *ChunkMesh) !void {
        for (0..CHUNK_SIZE) |z| {
            try self.mesh_slice(.front, z);
        }
        for (0..CHUNK_SIZE) |z| {
            try self.mesh_slice(.back, z);
        }
        for (0..CHUNK_SIZE) |x| {
            try self.mesh_slice(.right, x);
        }
        for (0..CHUNK_SIZE) |x| {
            try self.mesh_slice(.left, x);
        }
        for (0..CHUNK_SIZE) |y| {
            try self.mesh_slice(.top, y);
        }
        for (0..CHUNK_SIZE) |y| {
            try self.mesh_slice(.bot, y);
        }
    }

    const FaceSize = struct { w: usize = 0, h: usize = 0 };
    fn pack(self: *ChunkMesh, pos: World.BlockCoords, size: FaceSize, face: World.BlockFace) u32 {
        var res: u32 = 0;
        const x, const y, const z = .{ pos.x, pos.y, pos.z };
        const w, const h = .{ size.w, size.h };

        res |= @as(u32, @intCast(x)) << 28;
        res |= @as(u32, @intCast(y)) << 24;
        res |= @as(u32, @intCast(z)) << 20;
        res |= @as(u32, @intFromEnum(face)) << 16;
        res |= @as(u32, @intCast(w - 1)) << 12;
        res |= @as(u32, @intCast(h - 1)) << 8;
        res |= @as(u32, @intFromEnum(self.get(pos)));

        return res;
    }

    fn visible(self: *ChunkMesh, pos: World.BlockCoords, face: World.BlockFace) bool {
        const b = self.get(pos);
        if (b == .air) return false;
        const x, const y, const z = .{ pos.x, pos.y, pos.z };

        return switch (face) {
            .front => z + 1 == CHUNK_SIZE or self.get(.init(x, y, z + 1)) == .air,
            .back => z == 0 or self.get(.init(x, y, z - 1)) == .air,
            .right => x + 1 == CHUNK_SIZE or self.get(.init(x + 1, y, z)) == .air,
            .left => x == 0 or self.get(.init(x - 1, y, z)) == .air,
            .top => y + 1 == CHUNK_SIZE or self.get(.init(x, y + 1, z)) == .air,
            .bot => y == 0 or self.get(.init(x, y - 1, z)) == .air,
        };
    }

    fn mesh_slice(self: *ChunkMesh, comptime face: World.BlockFace, layer: usize) !void {
        const dir = BlockModel.scale[@intFromEnum(face)];
        const w_dim = dir[0..1];
        const h_dim = dir[1..2];
        const o_dim = dir[2..3];
        var visited = std.mem.zeroes([CHUNK_SIZE][CHUNK_SIZE]bool);
        for (0..CHUNK_SIZE) |i| {
            for (0..CHUNK_SIZE) |j| {
                var pos = World.BlockCoords{};
                if (visited[i][j]) continue;
                @field(pos, w_dim) = i;
                @field(pos, h_dim) = j;
                @field(pos, o_dim) = layer;
                if (!self.visible(pos, face)) continue;

                const size = if (Options.greedy_meshing)
                    self.greedy_size(pos, face, &visited)
                else
                    self.one_by_one_size(pos, face);
                try self.faces.append(App.gpa(), self.pack(pos, size, face));
            }
        }
    }
    fn one_by_one_size(self: *ChunkMesh, origin: World.BlockCoords, comptime face: World.BlockFace) FaceSize {
        if (self.visible(origin, face)) {
            return .{ .w = 1, .h = 1 };
        } else {
            return .{ .w = 0, .h = 0 };
        }
    }

    fn greedy_size(
        self: *ChunkMesh,
        origin: World.BlockCoords,
        comptime face: World.BlockFace,
        visited: *[CHUNK_SIZE][CHUNK_SIZE]bool,
    ) FaceSize {
        const dir = BlockModel.scale[@intFromEnum(face)];
        const w_dim = dir[0..1];
        const h_dim = dir[1..2];
        const o_dim = dir[2..3];
        const i_start = @field(origin, w_dim);
        const j_start = @field(origin, h_dim);
        std.debug.assert(!visited[i_start][j_start]);
        if (!self.visible(origin, face)) return .{};

        var limit: usize = CHUNK_SIZE;
        var best_size: FaceSize = .{ .w = 1, .h = 1 };
        const block = self.get(origin);

        for (i_start..CHUNK_SIZE) |i| {
            for (j_start..limit) |j| {
                var pos = World.BlockCoords{};
                @field(pos, w_dim) = i;
                @field(pos, h_dim) = j;
                @field(pos, o_dim) = @field(origin, o_dim);
                const cur_size = FaceSize{ .h = j - j_start + 1, .w = i - i_start + 1 };
                if (!self.visible(pos, face) or self.get(pos) != block or visited[i][j]) {
                    limit = j;
                    break;
                }
                if (cur_size.w * cur_size.h > best_size.w * best_size.h) {
                    best_size = cur_size;
                }
            }
            if (limit == j_start) break;
        }

        for (0..best_size.w) |i| {
            for (0..best_size.h) |j| {
                visited[i_start + i][j_start + j] = true;
            }
        }

        return best_size;
    }

    fn get(self: *ChunkMesh, pos: World.BlockCoords) World.BlockId {
        return self.chunk.?.get(pos);
    }
};

fn update_mesh(self: *Self, mesh: *ChunkMesh) !void {
    const actual_size = mesh.faces.items.len * @sizeOf(u32);
    const requested_size = @max(MINIMAL_MESH_SIZE, actual_size);
    if (mesh.handle == .invalid) {
        mesh.handle = try self.faces.alloc(requested_size, .@"4");
    } else {
        const range = self.faces.get_range(mesh.handle).?;
        try gl_call(gl.InvalidateBufferSubData(self.faces.buffer, range.offset, range.size));
        mesh.handle = try self.faces.realloc(mesh.handle, requested_size, .@"4");
    }
    if (actual_size == 0) {
        return;
    }

    const range = self.faces.get_range(mesh.handle).?;
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.faces.buffer));
    try gl_call(gl.BufferSubData(
        gl.ARRAY_BUFFER,
        range.offset,
        range.size,
        mesh.faces.items.ptr,
    ));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
}
