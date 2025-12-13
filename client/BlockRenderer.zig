const std = @import("std");
const App = @import("App.zig");
const World = @import("World.zig");
const Chunk = @import("Chunk.zig");
const Options = @import("ClientOptions");
const Log = @import("libmine").Log;
const gl = @import("gl");
const zm = @import("zm");
const GpuAlloc = @import("GpuAlloc.zig");
const Shader = @import("Shader.zig");
const Renderer = @import("Renderer.zig");
const util = @import("util.zig");
const gl_call = util.gl_call;
const BlockModel = @import("Block");
const c = @import("c.zig").c;

const Self = @This();
const BlockRenderer = @This();

const CHUNK_SIZE = World.CHUNK_SIZE;

const DEFAULT_FACES_SIZE = 1024 * 1024 * 16;
const DEFAULT_CHUNK_DATA_SIZE = 1024 * @sizeOf(ChunkData);
const DEFAULT_INDIRECT_SIZE = 1024 * @sizeOf(Indirect);

block_pass: Shader,
block_vao: gl.uint,
block_ibo: gl.uint,
block_ubo: gl.uint,
faces: GpuAlloc,
chunk_data_ssbo: gl.uint,
indirect_buf: gl.uint,

drawn_chunks_cnt: usize,
cur_chunk_data_ssbo_size: usize,

meshes: std.AutoArrayHashMapUnmanaged(World.ChunkCoords, *Mesh),
free_meshes: std.ArrayList(*Mesh),

pub fn init(self: *Self) !void {
    Log.log(.debug, "{*} Initializing...", .{self});

    self.drawn_chunks_cnt = 0;
    self.meshes = .empty;
    self.free_meshes = .empty;
    self.cur_chunk_data_ssbo_size = DEFAULT_CHUNK_DATA_SIZE;

    var sources: [2]Shader.Source = .{
        Shader.Source{
            .kind = gl.VERTEX_SHADER,
            .sources = &.{block_vert},
            .name = "block_vert",
        },
        Shader.Source{
            .kind = gl.FRAGMENT_SHADER,
            .sources = &.{block_frag},
            .name = "block_frag",
        },
    };
    self.block_pass = try .init(&sources);
    Log.log(.debug, "{*} Initialized block pass", .{self});

    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.block_vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_ubo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_data_ssbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buf)));
    self.faces = try .init(App.static_alloc(), DEFAULT_FACES_SIZE, gl.STREAM_DRAW);

    try gl_call(gl.BindVertexArray(self.block_vao));

    try self.init_block_model();
    Log.log(.debug, "{*} Initialized block model", .{self});
    try self.init_face_attribs();
    Log.log(.debug, "{*} Initialized face data buffers", .{self});
    try self.init_chunk_data();
    Log.log(.debug, "{*} Initialized chunk data buffers", .{self});

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    Log.log(.debug, "{*} Finished initializing...", .{self});
}

fn init_block_model(self: *Self) !void {
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.block_ibo));
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(block_inds.len * @sizeOf(u8)),
        @ptrCast(&block_inds),
        gl.STATIC_DRAW,
    ));

    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, self.block_ubo));
    try gl_call(gl.BufferData(
        gl.UNIFORM_BUFFER,
        @intCast(block_model.len * @sizeOf(f32)),
        @ptrCast(&block_model),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(gl.UNIFORM_BUFFER, BLOCK_MODEL_BINDING, self.block_ubo));
}

fn init_face_attribs(self: *Self) !void {
    try gl_call(gl.BindVertexBuffer(FACE_DATA_BINDING, self.faces.buffer, 0, @sizeOf(Face)));

    try gl_call(gl.EnableVertexAttribArray(FACE_DATA_LOCATION_A));
    try gl_call(gl.VertexAttribIFormat(FACE_DATA_LOCATION_A, 1, gl.UNSIGNED_INT, 0));
    try gl_call(gl.VertexAttribBinding(FACE_DATA_LOCATION_A, FACE_DATA_BINDING));

    try gl_call(gl.EnableVertexAttribArray(FACE_DATA_LOCATION_B));
    try gl_call(gl.VertexAttribIFormat(FACE_DATA_LOCATION_B, 1, gl.UNSIGNED_INT, @sizeOf(u32)));
    try gl_call(gl.VertexAttribBinding(FACE_DATA_LOCATION_B, FACE_DATA_BINDING));

    try gl_call(gl.VertexBindingDivisor(FACE_DATA_BINDING, 1));
}

fn init_chunk_data(self: *Self) !void {
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_data_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(self.cur_chunk_data_ssbo_size),
        null,
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        CHUNK_DATA_BINDING,
        self.chunk_data_ssbo,
    ));

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        DEFAULT_INDIRECT_SIZE,
        null,
        gl.STREAM_DRAW,
    ));
}

pub fn deinit(self: *Self) void {
    self.block_pass.deinit();
    self.faces.deinit();

    gl.DeleteVertexArrays(1, @ptrCast(&self.block_vao));
    gl.DeleteBuffers(1, @ptrCast(&self.block_ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.block_ubo));
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_data_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.indirect_buf));
}

pub fn draw(self: *Self) !void {
    const draw_count = try self.compute_drawn_chunk_data();

    const cam = &App.game_state().camera;

    try self.block_pass.set_mat4("u_view", cam.view_mat());
    try self.block_pass.set_mat4("u_proj", cam.proj_mat());
    try self.block_pass.bind();

    try gl_call(gl.BindVertexArray(self.block_vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));

    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        gl.UNSIGNED_BYTE,
        0,
        @intCast(draw_count),
        0,
    ));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
    try gl_call(gl.BindVertexArray(0));
}

pub fn on_frame_start(self: *Self) !void {
    try App.gui().add_to_frame(Self, "Debug", self, struct {
        fn callback(this: *Self) !void {
            const gpu_mem_faces: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
                App.frame_alloc(),
                \\GPU Memory:
                \\    faces: {f}
            ,
                .{util.MemoryUsage.from_bytes(this.faces.size)},
                0,
            ));
            c.igText("%s", gpu_mem_faces);
            c.igText("Chunks drawn: %zu", this.drawn_chunks_cnt);
        }
    }.callback, @src());
}

pub fn upload_chunk(self: *Self, chunk: *Chunk) !void {
    const mesh = if (self.free_meshes.pop()) |mesh| blk: {
        mesh.chunk = chunk;
        break :blk mesh;
    } else try Mesh.init(chunk);

    try mesh.update(self);

    try gl_call(gl.BindVertexArray(self.block_vao));
    try gl_call(gl.BindVertexBuffer(
        FACE_DATA_BINDING,
        self.faces.buffer,
        0,
        @sizeOf(Face),
    ));
    try gl_call(gl.BindVertexArray(0));
}

const MeshOrder = struct {
    mesh: *Mesh,
    dist_sq: f32,

    fn less_than(_: void, a: MeshOrder, b: MeshOrder) bool {
        return a.dist_sq < b.dist_sq;
    }
};

fn compute_drawn_chunk_data(self: *Self) !usize {
    const cam = &App.game_state().camera;
    var meshes: std.ArrayList(MeshOrder) = .empty;

    for (self.meshes.values()) |mesh| {
        const bound = mesh.chunk.bounding_sphere();
        const center = zm.vec.xyz(bound);
        const rad = bound[3];
        if (mesh.is_occluded(self)) continue;
        if (!cam.sphere_in_frustum(center, rad)) continue;

        try meshes.append(App.frame_alloc(), .{
            .mesh = mesh,
            .dist_sq = zm.vec.lenSq(cam.frustum.pos - center),
        });
    }
    std.mem.sort(MeshOrder, meshes.items, {}, MeshOrder.less_than);

    const indirect = try App.frame_alloc().alloc(Indirect, meshes.items.len);
    const chunk_data = try App.frame_alloc().alloc(ChunkData, meshes.items.len);

    @memset(indirect, std.mem.zeroes(Indirect));
    @memset(chunk_data, std.mem.zeroes(ChunkData));

    for (meshes.items, 0..) |mesh, i| {
        const range = self.faces.get_range(mesh.mesh.handle).?;

        indirect[i] = Indirect{
            .count = 6,
            .instance_count = @intCast(mesh.mesh.faces.items.len),
            .base_instance = @intCast(@divExact(range.offset, @sizeOf(Face))),
            .base_vertex = 0,
            .first_index = 0,
        };
        chunk_data[i] = ChunkData{
            .x = mesh.mesh.chunk.coords[0],
            .y = mesh.mesh.chunk.coords[1],
            .z = mesh.mesh.chunk.coords[2],
        };
    }

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        @intCast(indirect.len * @sizeOf(Indirect)),
        @ptrCast(indirect),
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_data_ssbo));
    const ssbo_size = chunk_data.len * @sizeOf(ChunkData);
    if (self.cur_chunk_data_ssbo_size <= ssbo_size) {
        self.cur_chunk_data_ssbo_size = ssbo_size * 2;
        try gl_call(gl.BufferData(
            gl.SHADER_STORAGE_BUFFER,
            @intCast(self.cur_chunk_data_ssbo_size),
            null,
            gl.STREAM_DRAW,
        ));
        try gl_call(gl.BindBufferBase(
            gl.SHADER_STORAGE_BUFFER,
            CHUNK_DATA_BINDING,
            self.chunk_data_ssbo,
        ));
    }
    try gl_call(gl.BufferSubData(
        gl.SHADER_STORAGE_BUFFER,
        0,
        @intCast(ssbo_size),
        @ptrCast(chunk_data),
    ));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    self.drawn_chunks_cnt = meshes.items.len;
    return meshes.items.len;
}

const ChunkData = extern struct {
    x: i32,
    y: i32,
    z: i32,
    padding: u32 = 0xbeefcafe,
};

const Face = packed struct(u64) {
    // A:
    x: u4,
    y: u4,
    z: u4,
    normal: u3,
    _unused1: u1 = 0,
    ao: u4,
    _unused2: u12 = 0xeba,
    // B:
    _unused3: u32 = 0xdeadbeef,

    fn define() [:0]const u8 {
        return 
        \\struct Face {
        \\  uvec3 pos;
        \\  uint n;
        \\  uint ao;
        \\};
        \\
        \\Face unpack(){
        \\  uint x = (vert_face_a >> uint(0)) & uint(0x0F);
        \\  uint y = (vert_face_a >> uint(4)) & uint(0x0F);
        \\  uint z = (vert_face_a >> uint(8)) & uint(0x0F);
        \\  uint n = (vert_face_a >> uint(12)) & uint(0x0F);
        \\  uint ao = (vert_face_a >> uint(16)) & uint(0x0F);
        \\  return Face(uvec3(x, y, z), n, ao);
        \\}
        ;
    }
};

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

const Mesh = struct {
    chunk: *Chunk,
    faces: std.ArrayList(Face),
    handle: GpuAlloc.Handle,
    occlusion: OcclusionMask,

    fn init(chunk: *Chunk) !*Mesh {
        const self = try App.static_alloc().create(Mesh);
        self.chunk = chunk;
        self.handle = .invalid;
        self.faces = .empty;
        return self;
    }

    fn build_mesh(self: *Mesh) !void {
        self.faces.clearRetainingCapacity();
        self.occlusion = .{};

        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{ 0, 0, @intCast(i) };
            self.occlusion.front = @intFromBool(try self.build_layer_mesh(.front, start));
        }
        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{
                CHUNK_SIZE - 1,
                0,
                @intCast(CHUNK_SIZE - 1 - i),
            };
            self.occlusion.back = @intFromBool(try self.build_layer_mesh(.back, start));
        }
        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{ @intCast(i), 0, CHUNK_SIZE - 1 };
            self.occlusion.right = @intFromBool(try self.build_layer_mesh(.right, start));
        }
        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{ @intCast(CHUNK_SIZE - 1 - i), 0, 0 };
            self.occlusion.left = @intFromBool(try self.build_layer_mesh(.left, start));
        }
        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{ 0, @intCast(i), 0 };
            self.occlusion.top = @intFromBool(try self.build_layer_mesh(.top, start));
        }
        for (0..CHUNK_SIZE) |i| {
            const start: World.BlockCoords = .{
                CHUNK_SIZE - 1,
                @intCast(CHUNK_SIZE - 1 - i),
                0,
            };
            self.occlusion.bot = @intFromBool(try self.build_layer_mesh(.bot, start));
        }
    }

    const ao_mask: [BLOCK_FACE_CNT][4]u4 = .{
        .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // front
        .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // back
        .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // right
        .{ 0b1000, 0b0100, 0b0001, 0b0010 }, // left
        .{ 0b1000, 0b0100, 0b0010, 0b0001 }, // top
        .{ 0b1000, 0b0100, 0b0010, 0b0001 }, // bot
    };

    fn build_layer_mesh(
        self: *Mesh,
        normal: World.BlockFace,
        start: World.BlockCoords,
    ) !bool {
        const right = -normal.left_dir();
        const left = -right;
        const up = normal.up_dir();
        const down = -up;
        const front = normal.front_dir();

        var is_full_layer = true;

        for (0..World.CHUNK_SIZE) |i| {
            for (0..World.CHUNK_SIZE) |j| {
                const u: i32 = @intCast(i);
                const v: i32 = @intCast(j);

                const pos = start +
                    @as(World.BlockCoords, @splat(u)) * right +
                    @as(World.BlockCoords, @splat(v)) * up;

                const block = self.chunk.get(pos);
                if (block == .air or self.chunk.is_solid(pos + front)) {
                    is_full_layer = false;
                    continue;
                }

                var ao: u4 = 0;
                const ao_idx: usize = @intFromEnum(normal);
                if (self.chunk.is_solid(pos + front + left)) ao |= ao_mask[ao_idx][0];
                if (self.chunk.is_solid(pos + front + right)) ao |= ao_mask[ao_idx][1];
                if (self.chunk.is_solid(pos + front + up)) ao |= ao_mask[ao_idx][2];
                if (self.chunk.is_solid(pos + front + down)) ao |= ao_mask[ao_idx][3];

                const face = Face{
                    .x = @intCast(pos[0]),
                    .y = @intCast(pos[1]),
                    .z = @intCast(pos[2]),
                    .normal = @intFromEnum(normal),
                    .ao = ao,
                };

                try self.faces.append(App.static_alloc(), face);
            }
        }

        return is_full_layer;
    }

    fn occludes(self: *Mesh, dir: World.BlockFace) bool {
        switch (dir) {
            inline else => |tag| return @field(self.occlusion, @tagName(tag)) == 1,
        }
    }

    fn is_occluded(self: *Mesh, renderer: *BlockRenderer) bool {
        for (Chunk.neighbours, World.BlockFace.list) |d, dir| {
            const coords = self.chunk.coords + d;
            const other = renderer.meshes.get(coords) orelse return false;
            const occluded = other.occludes(dir.flip());
            if (!occluded) return false;
        }
        return true;
    }

    const OcclusionMask = packed struct {
        front: u1 = 0,
        back: u1 = 0,
        left: u1 = 0,
        right: u1 = 0,
        top: u1 = 0,
        bot: u1 = 0,
    };

    fn update(self: *Mesh, renderer: *BlockRenderer) !void {
        try self.build_mesh();

        if (self.handle == .invalid) {
            self.handle = try renderer.faces.alloc(
                self.faces.items.len * @sizeOf(Face),
                std.mem.Alignment.of(Face),
            );
        } else {
            const old_range = renderer.faces.get_range(self.handle).?;

            try gl_call(gl.InvalidateBufferSubData(
                renderer.faces.buffer,
                old_range.offset,
                old_range.size,
            ));
            self.handle = try renderer.faces.realloc(
                self.handle,
                self.faces.items.len * @sizeOf(Face),
                std.mem.Alignment.of(Face),
            );
        }

        const range = renderer.faces.get_range(self.handle).?;

        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, renderer.faces.buffer));
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            range.offset,
            range.size,
            @ptrCast(self.faces.items),
        ));
        try renderer.meshes.put(App.static_alloc(), self.chunk.coords, self);
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    }
};

const block_verts = blk: {
    var res = std.mem.zeroes([BLOCK_VERT_CNT * 4]f32);

    for (BlockModel.faces, 0..) |face, n| {
        for (face, 0..) |v, p| {
            res[4 * (n * N_STRIDE + p * P_STRIDE) + 0] = v[0];
            res[4 * (n * N_STRIDE + p * P_STRIDE) + 1] = v[1];
            res[4 * (n * N_STRIDE + p * P_STRIDE) + 2] = v[2];
        }
    }

    break :blk res;
};

const block_normals = blk: {
    var res = std.mem.zeroes([BLOCK_FACE_CNT * 4]f32);
    for (BlockModel.normals, 0..) |normal, n| {
        res[4 * n + 0] = normal[0];
        res[4 * n + 1] = normal[1];
        res[4 * n + 2] = normal[2];
    }
    break :blk res;
};

const block_model = block_normals ++ block_verts;

const block_inds: [BlockModel.indices.len]u8 = BlockModel.indices;

const FACE_DATA_LOCATION_A = 0;
const FACE_DATA_LOCATION_B = 1;
const FACE_DATA_BINDING = 0;
const CHUNK_DATA_BINDING = 1;
const BLOCK_MODEL_BINDING = 2;
const BLOCK_FACE_CNT = BlockModel.normals.len;
const BLOCK_VERT_CNT = BLOCK_FACE_CNT * BlockModel.faces[0].len;
const P_STRIDE = 1;
const N_STRIDE = BlockModel.faces[0].len;

const block_vert =
    \\#version 460 core
    \\
++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_A {d}\n", .{FACE_DATA_LOCATION_A}) ++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_B {d}\n", .{FACE_DATA_LOCATION_B}) ++
    std.fmt.comptimePrint("\n#define CHUNK_DATA_BINDING {d}\n", .{CHUNK_DATA_BINDING}) ++
    std.fmt.comptimePrint("\n#define BLOCK_MODEL_BINDING {d}\n", .{BLOCK_MODEL_BINDING}) ++
    std.fmt.comptimePrint("\n#define BLOCK_FACE_CNT {d}\n", .{BLOCK_FACE_CNT}) ++
    std.fmt.comptimePrint("\n#define BLOCK_VERT_CNT {d}\n", .{BLOCK_VERT_CNT}) ++
    std.fmt.comptimePrint("\n#define N_STRIDE {d}\n", .{N_STRIDE}) ++
    std.fmt.comptimePrint("\n#define P_STRIDE {d}\n", .{P_STRIDE}) ++
    \\
    \\layout (location = FACE_DATA_LOCATION_A) in uint vert_face_a;
    \\layout (location = FACE_DATA_LOCATION_B) in uint vert_face_b;
++ Face.define() ++
    \\
    \\layout (std430, binding = CHUNK_DATA_BINDING) buffer ChunkData{
    \\  ivec4 chunk_coords[];
    \\};
    \\layout (std140, binding = BLOCK_MODEL_BINDING) uniform BlockModel {
    \\  vec3 normals[BLOCK_FACE_CNT];
    \\  vec3 verts[BLOCK_VERT_CNT];
    \\};
    \\
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\    
    \\vec2 uvs[4] = {vec2(0,0), vec2(0,1), vec2(1,1), vec2(1,0)};
    \\
    \\out vec3 frag_norm;
    \\out uint frag_ao;
    \\out vec2 frag_uv;
    \\out vec3 frag_color;
    \\out vec3 frag_pos;
    \\
    \\void main() {
    \\  Face face = unpack();
    \\
    \\  uint p = gl_VertexID;
    \\  vec3 normal = normals[face.n];
    \\  vec3 vert = verts[face.n * N_STRIDE + p * P_STRIDE] + face.pos;
    \\  vec3 chunk = vec3(chunk_coords[gl_DrawID].xyz);
    \\  vec4 view_pos = u_view * vec4(vert + chunk * 16, 1);
    \\  gl_Position = u_proj * view_pos;
    \\
    \\  frag_norm = (u_view * vec4(normal, 0)).xyz;
    \\  frag_ao = face.ao;
    \\  frag_uv = uvs[p];
    \\  frag_color = face.pos / 16.0;
    \\  frag_pos = view_pos.xyz;
    \\}
;

const block_frag =
    \\#version 460 core
++
    std.fmt.comptimePrint("\n#define BASE_TEX_ATTACHMENT {d}\n", .{Renderer.BASE_TEX_ATTACHMENT}) ++
    std.fmt.comptimePrint("\n#define POSITION_TEX_ATTACHMENT {d}\n", .{Renderer.POSITION_TEX_ATTACHMENT}) ++
    std.fmt.comptimePrint("\n#define NORMAL_TEX_ATTACHMENT {d}\n", .{Renderer.NORMAL_TEX_ATTACHMENT}) ++
    \\#define AO_LEFT 3
    \\#define AO_RIGHT 2
    \\#define AO_TOP 1
    \\#define AO_BOT 0
    \\
    \\layout (location=BASE_TEX_ATTACHMENT) out vec4 out_color;
    \\layout (location=POSITION_TEX_ATTACHMENT) out vec4 out_pos;
    \\layout (location=NORMAL_TEX_ATTACHMENT) out vec4 out_norm;
    \\
    \\in vec3 frag_color;
    \\in vec3 frag_norm;
    \\in vec3 frag_pos;
    \\in flat uint frag_ao;
    \\in vec2 frag_uv;
    \\
    \\uniform float u_ao_factor = 0.7;
    \\uniform bool u_enable_face_ao = true;
    \\
    \\float get_ao(vec2 uv, uint mask) {
    \\  float l = ((mask >> AO_LEFT) & 1) * (1 - uv.x) * (1 - u_ao_factor);
    \\  float r = ((mask >> AO_RIGHT) & 1) * uv.x * (1 - u_ao_factor);
    \\  float t = ((mask >> AO_TOP) & 1) * (1 - uv.y) * (1 - u_ao_factor);
    \\  float b = ((mask >> AO_BOT) & 1) * uv.y * (1 - u_ao_factor);
    \\  return 1 - (l + r + t + b) / 4;
    \\}
    \\void main() {
    \\  float ao = (u_enable_face_ao ? get_ao(frag_uv, frag_ao) : 1.0);
    \\  out_color = vec4(frag_color * ao, 1);
    \\  out_pos = vec4(frag_pos, 1);
    \\  out_norm = vec4(frag_norm, 1);
    \\}
;
