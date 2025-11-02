const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const std = @import("std");
const gl = @import("gl");
const zm = @import("zm");
const gl_call = @import("util.zig").gl_call;
const Shader = @import("Shader.zig");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const Block = @import("Block");
const GpuAlloc = @import("GpuAlloc.zig");

const CHUNK_SIZE = 16;
const EXPECTED_BUFFER_SIZE = 16 * 1024 * 1024;
const EXPECTED_LOADED_CHUNKS_COUNT = 512;
const DIM = 16;
const HEIGHT = 8;
const DEBUG_SIZE = DIM * DIM * HEIGHT * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE * 6;
const VERT_DATA_LOCATION = 0;
const CHUNK_DATA_BINDING = 1;
const DEBUG_DATA_BINDING = 2;
const BLOCK_DATA_BINDING = 3;
const VERT_DATA_BINDING = 4;

const VERT =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define BLOCK_FACE_COUNT {d}\n", .{Block.faces.len}) ++
    \\
++ std.fmt.comptimePrint("#define VERTS_PER_FACE {d}\n", .{Block.faces[0].len}) ++
    \\
++ std.fmt.comptimePrint("#define VERT_DATA_LOCATION {d}\n", .{VERT_DATA_LOCATION}) ++
    \\
++ std.fmt.comptimePrint("#define CHUNK_DATA_LOCATION {d}\n", .{CHUNK_DATA_BINDING}) ++
    \\
++ std.fmt.comptimePrint("#define DEBUG_DATA_LOCATION {d}\n", .{DEBUG_DATA_BINDING}) ++
    \\
++ std.fmt.comptimePrint("#define BLOCK_DATA_LOCATION {d}\n", .{BLOCK_DATA_BINDING}) ++
    \\layout (location = VERT_DATA_LOCATION) in uint vert_data;    // xxxxyyyy|zzzz?nnn|????????|tttttttt
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
++ (if (Options.chunk_debug_buffer)
    \\layout (std430, binding = DEBUG_DATA_LOCATION) buffer Debug { 
    \\  uint debug_vertex_ids[];
    \\};
    \\
else
    "") ++
    \\
    \\layout(std140, binding = BLOCK_DATA_LOCATION) uniform Block {
    \\  vec3 normals[BLOCK_FACE_COUNT];
    \\  vec3 faces[BLOCK_FACE_COUNT * VERTS_PER_FACE];
    \\};
    \\
    \\void main() {
    \\  uint x = (vert_data & uint(0xF0000000)) >> 28;
    \\  uint y = (vert_data & uint(0x0F000000)) >> 24;
    \\  uint z = (vert_data & uint(0x00F00000)) >> 20;
    \\  uint n = (vert_data & uint(0x000F0000)) >> 16;
    \\
    \\  frag_pos = vec3(x, y, z) + faces[n * VERTS_PER_FACE + gl_VertexID] + 16 * vec3(chunk_coords[gl_DrawID]);
    \\  frag_color = vec3(x, y, z) / 16.0;
    \\  frag_norm = normals[n];
    \\  gl_Position = u_vp * vec4(frag_pos, 1);
    \\}
;
const FRAG =
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

shader: Shader,
storage: ChunkStorage,

vao: gl.uint,
block_ibo: gl.uint,
block_ubo: gl.uint,
debug_buffer: if (Options.chunk_debug_buffer) gl.uint else void,

const World = @This();
pub fn init() !World {
    var self: World = undefined;
    try self.storage.init();
    try self.init_shader();
    try self.init_buffers();
    try self.init_chunks();

    return self;
}

const raw_faces: []const u8 = blk: {
    const faces_count = Block.faces.len;
    const verts_per_face = Block.faces[0].len;

    var normals_data = std.mem.zeroes([4 * faces_count]u32);
    for (Block.normals, 0..) |normal, i| {
        normals_data[1 + 4 * i + 0] = @bitCast(@as(f32, normal[0]));
        normals_data[1 + 4 * i + 1] = @bitCast(@as(f32, normal[1]));
        normals_data[1 + 4 * i + 2] = @bitCast(@as(f32, normal[2]));
    }
    var faces_data = std.mem.zeroes([4 * faces_count * verts_per_face]u32);
    for (Block.faces, 0..) |face, i| {
        for (face, 0..) |vertex, j| {
            const idx = i * verts_per_face + j;
            faces_data[4 * idx + 0] = @bitCast(@as(f32, vertex[0]));
            faces_data[4 * idx + 1] = @bitCast(@as(f32, vertex[1]));
            faces_data[4 * idx + 2] = @bitCast(@as(f32, vertex[2]));
        }
    }

    break :blk @ptrCast(&(normals_data ++ faces_data));
};

fn init_buffers(self: *World) !void {
    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_ubo)));

    if (Options.chunk_debug_buffer) {
        try gl_call(gl.GenBuffers(1, @ptrCast(&self.debug_buffer)));
    }

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.block_ibo));
    const inds: []const u8 = &Block.indices;
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(6 * @sizeOf(u8)),
        inds.ptr,
        gl.STATIC_DRAW,
    ));

    try gl_call(gl.BindVertexBuffer(VERT_DATA_BINDING, self.storage.faces.buffer, 0, @sizeOf(u32)));
    try gl_call(gl.EnableVertexAttribArray(VERT_DATA_LOCATION));
    try gl_call(gl.VertexAttribIFormat(VERT_DATA_LOCATION, 1, gl.UNSIGNED_INT, 0));
    try gl_call(gl.VertexAttribBinding(VERT_DATA_LOCATION, VERT_DATA_BINDING));
    try gl_call(gl.VertexBindingDivisor(VERT_DATA_BINDING, 1));

    if (Options.chunk_debug_buffer) {
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.debug_buffer));
        try gl_call(gl.BufferStorage(
            gl.SHADER_STORAGE_BUFFER,
            DEBUG_SIZE * @sizeOf(u32),
            null,
            gl.MAP_READ_BIT | gl.MAP_COHERENT_BIT | gl.MAP_PERSISTENT_BIT,
        ));
        try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, DEBUG_DATA_BINDING, self.debug_buffer));
    }

    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, self.block_ubo));
    try gl_call(gl.BufferStorage(
        gl.UNIFORM_BUFFER,
        @intCast(raw_faces.len),
        raw_faces.ptr,
        0,
    ));
    try gl_call(gl.BindBufferBase(gl.UNIFORM_BUFFER, BLOCK_DATA_BINDING, self.block_ubo));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.storage.chunk_coords_ssbo));
    try gl_call(gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, CHUNK_DATA_BINDING, self.storage.chunk_coords_ssbo));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
}

fn init_chunks(self: *World) !void {
    for (0..DIM) |i| {
        for (0..DIM) |j| {
            for (0..HEIGHT) |k| {
                const x = @as(i32, @intCast(i)) - DIM / 2;
                const y = @as(i32, @intCast(k)) - HEIGHT + 1;
                const z = @as(i32, @intCast(j)) - DIM / 2;
                try self.storage.request_chunk(.{ .x = x, .y = y, .z = z }, .{
                    .data = @ptrCast(self),
                    .on_stage = @ptrCast(&chunk_loading_callback),
                });
            }
        }
    }
}
fn chunk_loading_callback(self: *World, chunk: *Chunk) void {
    _ = self;
    _ = chunk;
}

pub fn deinit(self: *World) void {
    self.storage.deinit();

    gl.DeleteBuffers(1, @ptrCast(&self.block_ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.block_ubo));

    if (Options.chunk_debug_buffer) {
        gl.DeleteBuffers(1, @ptrCast(&self.debug_buffer));
    }
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));

    self.shader.deinit();
}

pub fn draw(self: *World) !void {
    try self.shader.set_vec3("u_view_pos", App.game_state().camera.pos);
    const vp = App.game_state().camera.as_mat();
    try self.shader.set_mat4("u_vp", vp);

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.storage.indirect_buffer));
    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        @field(gl, Block.index_type),
        0,
        @intCast(self.storage.active_chunks_count()),
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

pub fn process_chunks(self: *World) !void {
    for (0..100) |_| {
        _ = try self.storage.process_one();
    }
    try gl_call(gl.BindVertexArray(self.vao));
    try self.storage.regenerate_indirect();
    try gl_call(gl.BindVertexArray(0));
}

fn init_shader(self: *World) !void {
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
    try self.shader.set_vec3("u_ambient", .{ 0.1, 0.1, 0.1 });
    try self.shader.set_vec3("u_light_dir", zm.vec.normalize(zm.Vec3f{ 2, 1, 1 }));
    try self.shader.set_vec3("u_light_color", .{ 1, 1, 0.9 });
}

const BlockId = enum(u32) {
    air = 0,
    stone = 1,
    dirt = 2,
    grass = 3,
    _,
};

pub const Chunk = struct {
    coords: ChunkCoord,
    handle: GpuAlloc.Handle,
    stage: ChunkStorage.Stage,
    blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockId,
    face_data: std.ArrayListUnmanaged(u32),
    callbacks: std.ArrayListUnmanaged(ChunkCallback),
    active_chunk_index: usize,

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

    pub fn init(self: *Chunk, coords: ChunkCoord) void {
        self.* = .{
            .face_data = .empty,
            .coords = coords,
            .blocks = undefined,
            .callbacks = .empty,
            .stage = .ungenerated,
            .handle = .invalid,
            .active_chunk_index = 0,
        };
    }

    fn recommended_gpu_allocation_size(self: *Chunk) usize {
        _ = self;
        return 16 * 16 * 4 * @sizeOf(u32);
    }

    fn generate_grid(self: *Chunk) void {
        for (0..CHUNK_SIZE) |i| {
            for (0..CHUNK_SIZE) |j| {
                for (0..CHUNK_SIZE) |k| {
                    const x: i32 = (self.coords.x * CHUNK_SIZE + @as(i32, @intCast(i)));
                    const z: i32 = (self.coords.z * CHUNK_SIZE + @as(i32, @intCast(j)));
                    const y: i32 = (self.coords.y * CHUNK_SIZE + @as(i32, @intCast(k)));
                    const idx = i * I_OFFSET + j * J_OFFSET + k * K_OFFSET;
                    if (@rem(x + y + z, 2) == 0) {
                        self.blocks[idx] = .air;
                    } else {
                        self.blocks[idx] = .stone;
                    }
                }
            }
        }
    }

    fn generate(self: *Chunk) void {
        self.generate_balls();
    }

    fn generate_balls(self: *Chunk) void {
        const scale = std.math.pi / 8.0;
        for (0..CHUNK_SIZE) |i| {
            for (0..CHUNK_SIZE) |j| {
                for (0..CHUNK_SIZE) |k| {
                    const x: f32 = @floatFromInt(self.coords.x * CHUNK_SIZE + @as(i32, @intCast(i)));
                    const z: f32 = @floatFromInt(self.coords.z * CHUNK_SIZE + @as(i32, @intCast(j)));
                    const y: f32 = @floatFromInt(self.coords.y * CHUNK_SIZE + @as(i32, @intCast(k)));
                    const idx = i * I_OFFSET + j * J_OFFSET + k * K_OFFSET;
                    const w = @abs(@sin(x * scale) + @cos(z * scale) + @sin(y * scale));
                    if (w < 3 * 0.4) {
                        self.blocks[idx] = .air;
                    } else {
                        self.blocks[idx] = .stone;
                    }
                }
            }
        }
    }

    pub fn deinit(self: *Chunk) void {
        self.face_data.deinit(App.gpa());
        self.callbacks.deinit(App.gpa());
    }
};

const ChunkCoord = struct { x: i32, y: i32, z: i32 };

pub const ChunkCallback = struct {
    data: *anyopaque,
    on_stage: *const fn (*anyopaque, *Chunk) void,

    fn do(self: ChunkCallback, chunk: *Chunk) void {
        self.on_stage(self.data, chunk);
    }
};

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

const ChunkStorage = struct {
    faces: GpuAlloc,
    indirect_buffer: gl.uint,
    chunk_coords_ssbo: gl.uint,
    allocated_chunks_count: usize,

    chunk_worklist: std.ArrayListUnmanaged(*Chunk),
    active_chunks: std.AutoArrayHashMapUnmanaged(ChunkCoord, *Chunk),
    freelist: std.ArrayListUnmanaged(*Chunk),
    active_list_changed: bool,

    pub fn init(self: *ChunkStorage) !void {
        self.* = ChunkStorage{
            .faces = try .init(App.gpa(), EXPECTED_BUFFER_SIZE, gl.STREAM_DRAW),
            .indirect_buffer = 0,
            .chunk_coords_ssbo = 0,
            .chunk_worklist = .empty,
            .active_chunks = .empty,
            .freelist = .empty,
            .active_list_changed = false,
            .allocated_chunks_count = EXPECTED_LOADED_CHUNKS_COUNT,
        };

        try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buffer)));
        try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
        try gl_call(gl.BufferData(
            gl.DRAW_INDIRECT_BUFFER,
            @intCast(EXPECTED_LOADED_CHUNKS_COUNT * @sizeOf(Indirect)),
            null,
            gl.STREAM_DRAW,
        ));
        try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

        try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_coords_ssbo)));
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
        try gl_call(gl.BufferData(
            gl.SHADER_STORAGE_BUFFER,
            @intCast(EXPECTED_LOADED_CHUNKS_COUNT * @sizeOf(u32) * 4),
            null,
            gl.STREAM_DRAW,
        ));
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    }

    pub fn request_chunk(self: *ChunkStorage, coords: ChunkCoord, callback: ?ChunkCallback) !void {
        if (self.active_chunks.get(coords)) |exitsing| {
            if (callback) |cb| {
                try exitsing.callbacks.append(App.gpa(), cb);
                cb.do(exitsing);
            }
            return;
        }

        const new_chunk = if (self.freelist.pop()) |old|
            old
        else
            try App.gpa().create(Chunk);
        new_chunk.init(coords);
        try self.chunk_worklist.append(App.gpa(), new_chunk);
        if (callback) |cb| {
            try new_chunk.callbacks.append(App.gpa(), cb);
            cb.do(new_chunk);
        }
    }

    fn regenerate_indirect(self: *ChunkStorage) !void {
        if (!self.active_list_changed) return;
        self.active_list_changed = false;

        const count = self.active_chunks.values().len;
        const indirect = try App.frame_alloc().alloc(Indirect, count);
        const coords = try App.frame_alloc().alloc(i32, 4 * count);
        var total_primitives: usize = 0;
        for (self.active_chunks.values()) |chunk| {
            const range = self.faces.get_range(chunk.handle).?;
            indirect[chunk.active_chunk_index] = Indirect{
                .count = 6,
                .instance_count = @intCast(chunk.face_data.items.len),
                .base_instance = @intCast(@divExact(range.offset, 4)),
                .base_vertex = 0,
                .first_index = 0,
            };
            coords[4 * chunk.active_chunk_index + 0] = chunk.coords.x;
            coords[4 * chunk.active_chunk_index + 1] = chunk.coords.y;
            coords[4 * chunk.active_chunk_index + 2] = chunk.coords.z;
            total_primitives += 3 * chunk.face_data.items.len;
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
    }

    pub fn process_one(self: *ChunkStorage) !bool {
        while (self.chunk_worklist.pop()) |chunk| {
            switch (chunk.stage) {
                .dead => continue,
                .ungenerated => {
                    chunk.generate();
                    chunk.stage = .waiting_for_mesh;
                    try self.chunk_worklist.append(App.gpa(), chunk);
                    for (chunk.callbacks.items) |cb| {
                        cb.do(chunk);
                    }
                    return true;
                },
                .waiting_for_mesh => {
                    try chunk.build_mesh();
                    chunk.stage = .waiting_for_upload;
                    try self.chunk_worklist.append(App.gpa(), chunk);
                    for (chunk.callbacks.items) |cb| {
                        cb.do(chunk);
                    }
                    return true;
                },
                .waiting_for_upload => {
                    try self.upload(chunk);
                    chunk.stage = .active;
                    for (chunk.callbacks.items) |cb| {
                        cb.do(chunk);
                    }
                    try self.active_chunks.put(App.gpa(), chunk.coords, chunk);
                    chunk.active_chunk_index = self.active_chunks.values().len - 1;
                    self.active_list_changed = true;
                    return true;
                },
                else => {
                    Log.log(
                        .warn,
                        "{*}: dropping an unexpected stage-'{}' chunk {*} in the worklist",
                        .{ self, chunk.stage, chunk },
                    );
                    continue;
                },
            }
        }
        return false;
    }

    pub fn deinit(self: *ChunkStorage) void {
        for (self.chunk_worklist.items) |chunk| {
            chunk.deinit();
            App.gpa().destroy(chunk);
        }
        for (self.active_chunks.values()) |chunk| {
            chunk.deinit();
            App.gpa().destroy(chunk);
        }
        self.chunk_worklist.deinit(App.gpa());
        self.active_chunks.deinit(App.gpa());
        self.faces.deinit();
    }

    fn upload(self: *ChunkStorage, chunk: *Chunk) !void {
        const actual_size = chunk.face_data.items.len * @sizeOf(u32);
        const requested_size = @max(chunk.recommended_gpu_allocation_size(), actual_size);
        if (chunk.handle == .invalid) {
            chunk.handle = try self.faces.alloc(requested_size, .@"4");
        } else {
            const range = self.faces.get_range(chunk.handle).?;
            try gl_call(gl.InvalidateBufferSubData(self.faces.buffer, range.offset, range.size));
            chunk.handle = try self.faces.realloc(chunk.handle, requested_size, .@"4");
        }
        if (actual_size == 0) {
            return;
        }

        const range = self.faces.get_range(chunk.handle).?;
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.faces.buffer));
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            range.offset,
            range.size,
            chunk.face_data.items.ptr,
        ));
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    }

    const Stage = enum {
        dead,
        ungenerated,
        waiting_for_mesh,
        waiting_for_upload,
        active,
    };

    fn active_chunks_count(self: *ChunkStorage) usize {
        return self.active_chunks.count();
    }
};
