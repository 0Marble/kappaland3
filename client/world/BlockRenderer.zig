const std = @import("std");
const App = @import("../App.zig");
const Game = @import("../Game.zig");
const Chunk = @import("Chunk.zig");
const World = @import("../World.zig");
const Coords = World.Coords;
const gl = @import("gl");
const zm = @import("zm");
const GpuAlloc = @import("../GpuAlloc.zig");
const Shader = @import("../Shader.zig");
const Renderer = @import("../Renderer.zig");
const util = @import("../util.zig");
const gl_call = util.gl_call;
const Block = @import("../Block.zig");
const c = @import("../c.zig").c;
const OOM = std.mem.Allocator.Error;
const GlError = util.GlError;
const Camera = @import("../Camera.zig");

const logger = std.log.scoped(.block_renderer);

const Self = @This();
const BlockRenderer = @This();

const CHUNK_SIZE = Chunk.CHUNK_SIZE;

const DEFAULT_FACES_SIZE = 1024 * 1024 * 16;
const DEFAULT_CHUNK_DATA_SIZE = 1024 * @sizeOf(ChunkData);
const DEFAULT_INDIRECT_SIZE = 1024 * @sizeOf(Indirect);
const BLOCK_ATLAS_TEX = 0;

block_pass: Shader,
block_vao: gl.uint,
block_ibo: gl.uint,
model_ssbo: gl.uint,
normal_ubo: gl.uint,
faces: GpuAlloc,
had_realloc: bool,
chunk_data_ssbo: gl.uint,
indirect_buf: gl.uint,

drawn_chunks_cnt: usize,
shown_triangle_count: usize,
total_triangle_count: usize,
cur_chunk_data_ssbo_size: usize,

meshes: std.AutoArrayHashMapUnmanaged(Coords, *Mesh),
mesh_pool: std.heap.MemoryPool(Mesh),

pub fn init(self: *Self) !void {
    logger.debug("{*} Initializing...", .{self});

    self.had_realloc = false;
    self.drawn_chunks_cnt = 0;
    self.shown_triangle_count = 0;
    self.total_triangle_count = 0;
    self.meshes = .empty;
    self.mesh_pool = .init(App.gpa());
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
    self.block_pass = try .init(&sources, "block_pass");
    try self.block_pass.set_int("u_atlas", BLOCK_ATLAS_TEX);
    logger.debug("{*} Initialized block pass", .{self});

    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.block_vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.normal_ubo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.model_ssbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_data_ssbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buf)));
    self.faces = try .init(App.static_alloc(), DEFAULT_FACES_SIZE, gl.STREAM_DRAW);

    try gl_call(gl.BindVertexArray(self.block_vao));

    try self.init_models();
    logger.debug("{*} Initialized block model", .{self});
    try self.init_face_attribs();
    logger.debug("{*} Initialized face data buffers", .{self});
    try self.init_chunk_data();
    logger.debug("{*} Initialized chunk data buffers", .{self});

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try self.block_pass.observe_settings(".main.renderer.face_ao", bool, "u_enable_face_ao", @src());
    try self.block_pass.observe_settings(".main.renderer.face_ao_factor", f32, "u_ao_factor", @src());

    inline for (Ao.idx_to_ao, 0..) |ao, i| {
        const uni: [:0]const u8 = std.fmt.comptimePrint("u_idx_to_ao[{}]", .{i});
        try self.block_pass.set_uint(uni, @intCast(ao));
    }

    logger.debug("{*} Finished initializing...", .{self});
}

fn init_models(self: *Self) !void {
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.block_ibo));
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(Block.indices.len * @sizeOf(u8)),
        @ptrCast(Block.indices),
        gl.STATIC_DRAW,
    ));

    const normals_data = normals ++ normal_mats;
    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, self.normal_ubo));
    try gl_call(gl.BufferData(
        gl.UNIFORM_BUFFER,
        @intCast(normals_data.len * @sizeOf(f32)),
        @ptrCast(&normals_data),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(gl.UNIFORM_BUFFER, NORMAL_BINDING, self.normal_ubo));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.model_ssbo));

    const models: []const Block.Face = App.assets().get_blocks().models.keys();

    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(models.len * @sizeOf(Block.Face)),
        @ptrCast(models),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        MODEL_BINDING,
        self.model_ssbo,
    ));
}

fn init_face_attribs(self: *Self) !void {
    try gl_call(gl.BindVertexBuffer(
        FACE_DATA_BINDING,
        self.faces.buffer,
        0,
        @sizeOf(FaceMesh),
    ));

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
    self.mesh_pool.deinit();
    self.meshes.deinit(App.gpa());

    gl.DeleteVertexArrays(1, @ptrCast(&self.block_vao));
    gl.DeleteBuffers(1, @ptrCast(&self.block_ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.normal_ubo));
    gl.DeleteBuffers(1, @ptrCast(&self.model_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_data_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.indirect_buf));
}

pub fn draw(self: *Self, cam: *Camera) (OOM || GlError)!void {
    if (self.had_realloc) {
        try gl_call(gl.BindVertexArray(self.block_vao));
        try gl_call(gl.BindVertexBuffer(
            FACE_DATA_BINDING,
            self.faces.buffer,
            0,
            @sizeOf(FaceMesh),
        ));
        try gl_call(gl.BindVertexArray(0));
        self.had_realloc = false;
    }

    const draw_count = try self.compute_drawn_chunk_data(cam);

    try self.block_pass.set_mat4("u_view", cam.view_mat());
    try self.block_pass.set_mat4("u_proj", cam.proj_mat());
    try self.block_pass.bind();

    try gl_call(gl.BindVertexArray(self.block_vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));
    try gl_call(gl.ActiveTexture(gl.TEXTURE0 + BLOCK_ATLAS_TEX));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D_ARRAY, App.assets().get_blocks_atlas().handle));

    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        gl.UNSIGNED_BYTE,
        0,
        @intCast(draw_count),
        0,
    ));

    try gl_call(gl.BindTexture(gl.TEXTURE_2D_ARRAY, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
    try gl_call(gl.BindVertexArray(0));
}

pub fn upload_chunk_mesh(self: *Self, chunk: *Chunk) !void {
    const old_buf = self.faces.buffer;

    const mesh = if (self.meshes.get(chunk.coords)) |mesh| blk: {
        for (&mesh.handles, &chunk.faces.values) |*handle, faces| {
            const old_range = self.faces.get_range(handle.*).?;
            const new_size = faces.items.len * @sizeOf(FaceMesh);

            try gl_call(gl.InvalidateBufferSubData(
                self.faces.buffer,
                old_range.offset,
                old_range.size,
            ));
            handle.* = try self.faces.realloc(
                handle.*,
                new_size,
                std.mem.Alignment.of(FaceMesh),
            );
        }
        break :blk mesh;
    } else blk: {
        const mesh: *Mesh = try self.mesh_pool.create();
        for (&mesh.handles, &chunk.faces.values) |*handle, faces| {
            const new_size = faces.items.len * @sizeOf(FaceMesh);
            handle.* = try self.faces.alloc(
                new_size,
                std.mem.Alignment.of(FaceMesh),
            );
        }
        try self.meshes.put(App.gpa(), chunk.coords, mesh);
        break :blk mesh;
    };

    mesh.is_occluded = chunk.is_occluded;
    mesh.coords = chunk.coords;
    for (&mesh.face_counts, &chunk.faces.values, mesh.handles, 0..) |*cnt, faces, handle, i| {
        cnt.* = faces.items.len;
        self.total_triangle_count += faces.items.len * 2;

        const range = self.faces.get_range(handle).?;
        logger.debug(
            "{*}: chunk {}: mesh[{d}] {}: offset={d}, size={d}",
            .{ self, mesh.coords, i, handle, range.offset, range.size },
        );

        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.faces.buffer));
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            range.offset,
            range.size,
            @ptrCast(faces.items),
        ));
    }
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));

    self.had_realloc |= old_buf != self.faces.buffer;
}

pub fn destroy_chunk_mesh(self: *Self, coords: Coords) !void {
    const kv = self.meshes.fetchSwapRemove(coords) orelse return;
    const mesh = kv.value;
    for (mesh.handles, mesh.face_counts) |handle, cnt| {
        self.total_triangle_count -= cnt * 2;
        self.faces.free(handle);
    }

    self.mesh_pool.destroy(mesh);
}

fn on_imgui(self: *Self) !void {
    const gpu_mem_faces: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        \\Meshes: 
        \\    total:     {d}
        \\    drawn:     {d}
        \\    triangles: {d}/{d}
        \\GPU Memory:
        \\    faces:      {f}
        \\    chunk_ssbo: {f}
    ,
        .{
            self.meshes.count(),
            self.drawn_chunks_cnt,
            self.shown_triangle_count,
            self.total_triangle_count,
            util.MemoryUsage.from_bytes(self.faces.size),
            util.MemoryUsage.from_bytes(self.cur_chunk_data_ssbo_size),
        },
        0,
    ));
    c.igText("%s", gpu_mem_faces);
}

pub fn on_frame_start(self: *Self) !void {
    try App.gui().add_to_frame(Self, "Debug", self, on_imgui, @src());
}

const MeshOrder = struct {
    mesh: *Mesh,
    dist_sq: f32,

    fn less_than(_: void, a: MeshOrder, b: MeshOrder) bool {
        return a.dist_sq < b.dist_sq;
    }
};

fn compute_drawn_chunk_data(self: *Self, cam: *Camera) !usize {
    const do_frustum_culling = App.settings().get_value(
        bool,
        ".main.renderer.frustum_culling",
    );
    const do_occlusion_culling = App.settings().get_value(
        bool,
        ".main.renderer.occlusion_culling",
    );

    const cam_chunk = cam.chunk_coords();
    var meshes: std.ArrayList(MeshOrder) = .empty;
    self.shown_triangle_count = 0;

    for (self.meshes.values()) |mesh| {
        const bound = mesh.bounding_sphere();
        const center = zm.vec.xyz(bound);
        const rad = bound[3];
        if (do_frustum_culling and !cam.sphere_in_frustum(center, rad)) continue;

        if (do_occlusion_culling and
            !@reduce(.And, mesh.coords == cam_chunk) and
            mesh.is_occluded)
            continue;

        try meshes.append(App.frame_alloc(), .{
            .mesh = mesh,
            .dist_sq = zm.vec.lenSq(cam.frustum.pos - center),
        });
    }
    std.mem.sort(MeshOrder, meshes.items, {}, MeshOrder.less_than);

    const indirect = try App.frame_alloc().alloc(Indirect, meshes.items.len * BLOCK_FACE_CNT);
    const chunk_data = try App.frame_alloc().alloc(ChunkData, meshes.items.len * BLOCK_FACE_CNT);

    @memset(indirect, std.mem.zeroes(Indirect));
    @memset(chunk_data, std.mem.zeroes(ChunkData));

    for (meshes.items, 0..) |mesh, i| {
        for (std.enums.values(Block.Direction)) |normal| {
            const j: u32 = @intFromEnum(normal);
            const range = self.faces.get_range(mesh.mesh.handles[j]).?;

            indirect[i * BLOCK_FACE_CNT + j] = Indirect{
                .count = 6,
                .instance_count = @intCast(mesh.mesh.face_counts[j]),
                .base_instance = @intCast(@divExact(range.offset, @sizeOf(FaceMesh))),
                .base_vertex = 0,
                .first_index = 0,
            };
            chunk_data[i * BLOCK_FACE_CNT + j] = ChunkData{
                .x = mesh.mesh.coords[0],
                .y = mesh.mesh.coords[1],
                .z = mesh.mesh.coords[2],
                .normal = j,
            };
            self.shown_triangle_count += mesh.mesh.face_counts[j] * 2;
        }
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
    return indirect.len;
}

const ChunkData = extern struct {
    x: i32,
    y: i32,
    z: i32,
    normal: u32,
};

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

const Mesh = struct {
    handles: [BLOCK_FACE_CNT]GpuAlloc.Handle,
    face_counts: [BLOCK_FACE_CNT]usize,
    coords: Coords,
    is_occluded: bool,

    pub fn bounding_sphere(self: *Mesh) zm.Vec4f {
        const size: zm.Vec3f = @splat(CHUNK_SIZE);
        const coords: zm.Vec3f = @floatFromInt(self.coords);
        const pos = coords * size + size * @as(zm.Vec3f, @splat(0.5));
        const rad: f32 = @as(f32, @floatFromInt(CHUNK_SIZE)) * @sqrt(3.0) / 2.0;

        return .{ pos[0], pos[1], pos[2], rad };
    }
};

const normals = blk: {
    var res = std.mem.zeroes([BLOCK_FACE_CNT * 4]f32);
    for (std.enums.values(Block.Direction), 0..) |face, n| {
        const normal: zm.Vec3f = @floatFromInt(face.front_dir());
        res[4 * n + 0] = normal[0];
        res[4 * n + 1] = normal[1];
        res[4 * n + 2] = normal[2];
    }
    break :blk res;
};

// convert from normal-local coordinates (normal is +z)
// to model coordinates
// column major as per glsl spec
const normal_mats = blk: {
    const n = 12;
    var res = std.mem.zeroes([BLOCK_FACE_CNT * n]f32);
    for (std.enums.values(Block.Direction), 0..) |dir, i| {
        const right: zm.Vec3f = @floatFromInt(-dir.left_dir());
        const up: zm.Vec3f = @floatFromInt(dir.up_dir());
        const front: zm.Vec3f = @floatFromInt(dir.front_dir());
        const mat = [n]f32{
            right[0], right[1], right[2], 0,
            up[0],    up[1],    up[2],    0,
            front[0], front[1], front[2], 0,
        };
        @memcpy(res[n * i .. n * (i + 1)], &mat);
    }

    break :blk res;
};

const FACE_DATA_LOCATION_A = 0;
const FACE_DATA_LOCATION_B = 1;
const FACE_DATA_BINDING = 0;
const CHUNK_DATA_BINDING = 1;
const NORMAL_BINDING = 2;
const MODEL_BINDING = 3;
const BLOCK_FACE_CNT = std.enums.values(Block.Direction).len;

const block_vert =
    \\#version 460 core
    \\
++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_A {d}", .{FACE_DATA_LOCATION_A}) ++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_B {d}", .{FACE_DATA_LOCATION_B}) ++
    std.fmt.comptimePrint("\n#define CHUNK_DATA_BINDING {d}", .{CHUNK_DATA_BINDING}) ++
    std.fmt.comptimePrint("\n#define NORMAL_BINDING {d}", .{NORMAL_BINDING}) ++
    std.fmt.comptimePrint("\n#define MODEL_BINDING {d}", .{MODEL_BINDING}) ++
    std.fmt.comptimePrint("\n#define BLOCK_FACE_CNT {d}", .{BLOCK_FACE_CNT}) ++
    \\
    \\layout (location = FACE_DATA_LOCATION_A) in uint vert_face_a;
    \\layout (location = FACE_DATA_LOCATION_B) in uint vert_face_b;
    \\
    \\struct Face {
    \\  uvec3 pos;
    \\  uint ao;
    \\  uint model;
    \\  uint texture;
    \\};
    \\
    \\Face unpack_face(){
    \\  uint x = (vert_face_a >> uint(0)) & uint(0x0F);
    \\  uint y = (vert_face_a >> uint(4)) & uint(0x0F);
    \\  uint z = (vert_face_a >> uint(8)) & uint(0x0F);
    \\  uint ao = (vert_face_a >> uint(12)) & uint(0x3F);
    \\  uint model = (vert_face_a >> uint(18)) & uint(0x3FF);
    \\  uint tex = (vert_face_b >> uint(0)) & uint(0xFFFF);
    \\  return Face(uvec3(x, y, z), ao, model, tex);
    \\}
    \\
++ std.fmt.comptimePrint("uniform uint u_idx_to_ao[{}];\n", .{Ao.idx_to_ao.len}) ++
    \\struct Chunk {
    \\  int x;
    \\  int y;
    \\  int z;
    \\  uint normal;
    \\};
    \\
    \\layout (std430, binding = CHUNK_DATA_BINDING) buffer ChunkData{
    \\  Chunk chunks[];
    \\};
    \\
    \\layout (std430, binding = MODEL_BINDING) buffer Models {
    \\  uint raw_model[];
    \\};
    \\
    \\struct Model {
    \\  vec2 scale;
    \\  vec3 offset;
    \\};
    \\
    \\Model unpack_model(uint model_idx) {
    \\  uint x = raw_model[model_idx];
    \\  return Model(
    \\    vec2(
    \\      float(((x >> uint(0)) & uint(0xF)) + 1) / 16.0,
    \\      float(((x >> uint(4)) & uint(0xF)) + 1) / 16.0
    \\    ),
    \\    vec3(
    \\      float((x >> uint(8)) & uint(0xF)) / 16.0,
    \\      float((x >> uint(12)) & uint(0xF)) / 16.0,
    \\      float((x >> uint(16)) & uint(0xF)) / 16.0
    \\    )
    \\  );
    \\}
    \\
    \\layout (std140, binding = NORMAL_BINDING) uniform Normals {
    \\  vec3 normals[BLOCK_FACE_CNT];
    \\  mat3 norm_to_world[BLOCK_FACE_CNT];
    \\};
    \\
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\
    \\vec2 uvs[4] = {vec2(0,0), vec2(0,1), vec2(1,1), vec2(1,0)};
    \\
    \\out vec3 frag_norm;
    \\out uint frag_ao;
    \\out uint frag_tex;
    \\out vec2 frag_uv;
    \\out vec3 frag_pos;
    \\out vec3 frag_color;
    \\
    \\void main() {
    \\  Face face = unpack_face();
    \\  Model model = unpack_model(face.model);
    \\  Chunk chunk = chunks[gl_DrawID];
    \\
    \\  uint p = gl_VertexID;
    \\  vec3 normal = normals[chunk.normal];
    \\  frag_uv = uvs[p] * model.scale + model.offset.xy;
    \\  vec3 vert = norm_to_world[chunk.normal] * vec3(frag_uv - vec2(0.5, 0.5), 0.5 - model.offset.z) + face.pos + vec3(0.5,0.5,0.5);
    \\  vec3 chunk_coords = vec3(chunk.x, chunk.y, chunk.z);
    \\  vec4 view_pos = u_view * vec4(vert + chunk_coords * 16, 1);
    \\  gl_Position = u_proj * view_pos;
    \\
    \\  frag_norm = (u_view * vec4(normal, 0)).xyz;
    \\  frag_ao = u_idx_to_ao[face.ao];
    \\  frag_tex = face.texture;
    \\  frag_pos = view_pos.xyz;
    \\  frag_color = vec3(1);
    \\}
;

const block_frag =
    \\#version 460 core
++
    std.fmt.comptimePrint("\n#define BASE_TEX_ATTACHMENT {d}", .{Renderer.BASE_TEX_ATTACHMENT}) ++
    std.fmt.comptimePrint("\n#define POSITION_TEX_ATTACHMENT {d}", .{Renderer.POSITION_TEX_ATTACHMENT}) ++
    std.fmt.comptimePrint("\n#define NORMAL_TEX_ATTACHMENT {d}", .{Renderer.NORMAL_TEX_ATTACHMENT}) ++
    \\
    \\layout (location=BASE_TEX_ATTACHMENT) out vec4 out_color;
    \\layout (location=POSITION_TEX_ATTACHMENT) out vec4 out_pos;
    \\layout (location=NORMAL_TEX_ATTACHMENT) out vec4 out_norm;
    \\
    \\in flat uint frag_tex;
    \\in vec3 frag_norm;
    \\in vec3 frag_pos;
    \\in flat uint frag_ao;
    \\in vec2 frag_uv;
    \\in vec3 frag_color;
    \\
    \\uniform bool u_enable_face_ao = true;
    \\uniform float u_ao_factor = 0.7;
    \\uniform sampler2DArray u_atlas;
++ std.fmt.comptimePrint(
    \\
    \\float get_ao() {{
    \\  #define GET(dir) float((frag_ao >> uint(dir)) & uint(1))
    \\  #define CORNER(v) (1.0 - clamp(abs(frag_uv.x - (v).x) + abs(frag_uv.y - (v).y), 0, 1))
    \\  float l = GET({}) * (1.0 - frag_uv.x);
    \\  float r = GET({}) * (frag_uv.x);
    \\  float t = GET({}) * (frag_uv.y);
    \\  float b = GET({}) * (1.0 - frag_uv.y);
    \\  float tl = GET({}) * CORNER(vec2(0, 1));
    \\  float tr = GET({}) * CORNER(vec2(1, 1));
    \\  float bl = GET({}) * CORNER(vec2(0, 0));
    \\  float br = GET({}) * CORNER(vec2(1, 0));
    \\  float ao = (l + r + t + b + tl + tr + bl + br) / 4.0;
    \\  return smoothstep(0.0, 1.0, ao);
    \\  #undef GET
    \\  #undef CORNER
    \\}}
    \\
, .{ Ao.L, Ao.R, Ao.T, Ao.B, Ao.TL, Ao.TR, Ao.BL, Ao.BR }) ++
    \\
    \\void main() {
    \\  float ao = (u_enable_face_ao ? 1.0 - get_ao() * u_ao_factor : 1.0);
    \\  vec3 rgb = texture(u_atlas, vec3(vec2(frag_uv.x, 1 - frag_uv.y), float(frag_tex))).rgb;
    \\  out_color = vec4(rgb * ao * frag_color, 1);
    \\  out_pos = vec4(frag_pos, 1);
    \\  out_norm = vec4(frag_norm, 1);
    \\}
;

pub const FaceMesh = packed struct(u64) {
    // A:
    x: u4,
    y: u4,
    z: u4,
    ao: u6,
    model: u10 = 0,
    _unused2: u4 = 0b1010,
    // B:
    texture: u16,
    _unused3: u16 = 0xdead,
};

pub const Ao = struct {
    const ao_to_idx = precalculated[1];
    pub const idx_to_ao = precalculated[0];

    const L = 0;
    const R = 1;
    const T = 2;
    const B = 3;
    const TL = 4;
    const TR = 5;
    const BL = 6;
    const BR = 7;

    fn normalize(x: u8) u8 {
        const l = (x >> L) & 1;
        const r = (x >> R) & 1;
        const t = (x >> T) & 1;
        const b = (x >> B) & 1;
        const tl = (x >> TL) & 1;
        const tr = (x >> TR) & 1;
        const bl = (x >> BL) & 1;
        const br = (x >> BR) & 1;
        return pack(l, r, t, b, tl, tr, bl, br);
    }

    fn pack(l: u8, r: u8, t: u8, b: u8, tl: u8, tr: u8, bl: u8, br: u8) u8 {
        return (l << L) |
            (r << R) |
            (t << T) |
            (b << B) |
            ((tl * (1 - l) * (1 - t)) << TL) |
            ((tr * (1 - r) * (1 - t)) << TR) |
            ((bl * (1 - l) * (1 - b)) << BL) |
            ((br * (1 - r) * (1 - b)) << BR);
    }

    const precalculated = blk: {
        @setEvalBranchQuota(std.math.maxInt(u32));
        const UNIQUE_CNT = 47;
        var to_ao: [UNIQUE_CNT]u8 = @splat(0);
        var to_idx: [256]u8 = @splat(0);

        var i: usize = 0;
        for (0..256) |x| {
            const y = normalize(x);
            const k = l1: for (0..i) |j| {
                if (to_ao[j] == y) break :l1 j;
            } else l2: {
                to_ao[i] = y;
                i += 1;
                break :l2 i - 1;
            };
            to_idx[x] = k;
        }
        std.debug.assert(i == UNIQUE_CNT);
        break :blk .{ to_ao, to_idx };
    };
};
