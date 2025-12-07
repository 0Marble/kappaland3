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
const Camera = @import("Camera.zig");
const c = @import("c.zig").c;
const Ecs = @import("libmine").Ecs;
const Occlusion = @import("Occlusion.zig");

const CHUNK_SIZE = World.CHUNK_SIZE;
const EXPECTED_BUFFER_SIZE = 16 * 1024 * 1024;
const EXPECTED_LOADED_CHUNKS_COUNT = World.DIM * World.DIM * World.HEIGHT;
const MINIMAL_MESH_SIZE = @sizeOf(VertexData) * 1024;
const VERT_DATA_LOCATION_A = 0;
const VERT_DATA_LOCATION_B = 1;
const CHUNK_DATA_BINDING = 1;
const BLOCK_DATA_BINDING = 3;
const VERT_DATA_BINDING = 4;
const BLOCK_FACE_COUNT = BlockModel.faces.len;
const VERTS_PER_FACE = BlockModel.faces[0].len;
const N_OFFSET = VERTS_PER_FACE * CHUNK_SIZE * CHUNK_SIZE;
const W_OFFSET = VERTS_PER_FACE * CHUNK_SIZE;
const H_OFFSET = VERTS_PER_FACE;
const P_OFFSET = 1;

const VertexData = u64;

const VERT =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define BLOCK_FACE_COUNT {d}\n", .{BLOCK_FACE_COUNT}) ++
    \\
++ std.fmt.comptimePrint("#define VERTS_PER_FACE {d}\n", .{VERTS_PER_FACE}) ++
    \\
++ std.fmt.comptimePrint("#define VERT_DATA_LOCATION_A {d}\n", .{VERT_DATA_LOCATION_A}) ++
    \\
++ std.fmt.comptimePrint("#define VERT_DATA_LOCATION_B {d}\n", .{VERT_DATA_LOCATION_B}) ++
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
    \\layout (location = VERT_DATA_LOCATION_A) in uint vert_data_a;    // xxxxyyyy|zzzz?nnn|wwwwhhhh|tttttttt
    \\layout (location = VERT_DATA_LOCATION_B) in uint vert_data_b;    // oooo????|????????|????????|????????
    \\                                            // per instance
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\
    \\out vec3 frag_norm;
    \\out vec2 frag_uv;
    \\out vec3 frag_color;
    \\out vec3 frag_pos;
    \\out ivec3 block_coords;
    \\out uint frag_occlusion;
    \\
    \\layout (std430, binding = CHUNK_DATA_LOCATION) buffer Chunk {
    \\  ivec3 chunk_coords[];
    \\};
    \\
    \\layout (std140, binding = BLOCK_DATA_LOCATION) uniform Block {
    \\  vec3 normals[BLOCK_FACE_COUNT];
    \\  vec3 faces[BLOCK_FACE_COUNT * VERTS_PER_FACE * CHUNK_SIZE * CHUNK_SIZE];
    \\};
    \\vec3 colors[4] = {vec3(0,0,0),vec3(0.2,0.2,0.2),vec3(0.6,0.4,0.2),vec3(0.2,0.7,0.3)};
    \\vec2 uvs[4] = {vec2(0,0), vec2(0,1), vec2(1,1), vec2(1,0)};
    \\
    \\void main() {
    \\  uint x = (vert_data_a & uint(0xF0000000)) >> 28;
    \\  uint y = (vert_data_a & uint(0x0F000000)) >> 24;
    \\  uint z = (vert_data_a & uint(0x00F00000)) >> 20;
    \\  uint n = (vert_data_a & uint(0x000F0000)) >> 16;
    \\  uint w = (vert_data_a & uint(0x0000F000)) >> 12;
    \\  uint h = (vert_data_a & uint(0x00000F00)) >> 8;
    \\  uint t = (vert_data_a & uint(0x000000FF));
    \\  uint o = (vert_data_b & uint(0xF0000000)) >> 28;
    \\
    \\  uint p = gl_VertexID;
    \\  uint face = w * W_OFFSET + h * H_OFFSET + p * P_OFFSET + n * N_OFFSET;
    \\
    \\  frag_occlusion = o;
    \\  frag_uv = uvs[p];
    \\  block_coords = ivec3(x, y, z) + 16 * chunk_coords[gl_DrawID];
    \\  frag_pos = (u_view * vec4(faces[face] + block_coords, 1)).xyz;
    \\  frag_norm = (u_view * vec4(normals[n], 0)).xyz;
    \\  frag_color = vec3(x, y, z) / 16.0;
    \\  gl_Position = u_proj * vec4(frag_pos, 1);
    \\}
;

const FRAG =
    \\#version 460 core
    \\
++ std.fmt.comptimePrint("#define BASE_COLOR_LOCATION {d}\n", .{Renderer.BASE_TEX_ATTACHMENT}) ++
    \\
++ std.fmt.comptimePrint("#define POSITION_LOCATION {d}\n", .{Renderer.POSITION_TEX_ATTACHMENT}) ++
    \\
++ std.fmt.comptimePrint("#define NORMAL_LOCATION {d}\n", .{Renderer.NORMAL_TEX_ATTACHMENT}) ++
    \\
    \\#define AO_LEFT 3
    \\#define AO_RIGHT 2
    \\#define AO_TOP 1
    \\#define AO_BOT 0
    \\
    \\in vec3 frag_color;
    \\in vec3 frag_norm;
    \\in vec3 frag_pos;
    \\in flat ivec3 block_coords;
    \\in flat uint frag_occlusion;
    \\in vec2 frag_uv;
    \\
    \\layout (location=BASE_COLOR_LOCATION) out vec4 out_color;
    \\layout (location=POSITION_LOCATION) out vec4 out_pos;
    \\layout (location=NORMAL_LOCATION) out vec4 out_norm;
    \\
    \\uniform float u_occlusion_factor = 0.7;
    \\uniform bool u_enable_face_occlusion = true;
    \\
    \\float get_occlusion(uint mask, uint dir) {
    \\  return ((mask & uint(1 << dir)) == 0 ? 0 : 1);
    \\}
    \\float occlusion(vec2 uv, uint mask) {
    \\  float l = get_occlusion(mask, AO_LEFT) * (1 - uv.x) * (1 - u_occlusion_factor);
    \\  float r = get_occlusion(mask, AO_RIGHT) * uv.x * (1 - u_occlusion_factor);
    \\  float t = get_occlusion(mask, AO_TOP) * (1 - uv.y) * (1 - u_occlusion_factor);
    \\  float b = get_occlusion(mask, AO_BOT) * uv.y * (1 - u_occlusion_factor);
    \\  return 1 - (l + r + t + b) / 4;
    \\}
    \\
    \\void main() {
    \\  out_color = vec4(frag_color, 1) * (u_enable_face_occlusion ? occlusion(frag_uv, frag_occlusion) : 1);
    \\  out_pos = vec4(frag_pos, 1);
    \\  out_norm = vec4(frag_norm, 1);
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
seen_cnt: usize,

eid: Ecs.EntityRef,

const Self = @This();

pub fn init(self: *Self) !void {
    self.meshes_changed = false;
    self.meshes = .empty;
    self.freelist = .empty;
    self.triangle_count = 0;
    self.seen_cnt = 0;

    try self.init_buffers();
    try self.init_shader();

    self.eid = try App.ecs().spawn();
    try self.on_setting_change_set_uniform(".main.renderer.face_ao", "shader", "u_enable_face_occlusion", bool);
    try self.on_setting_change_set_uniform(".main.renderer.face_ao_factor", "shader", "u_occlusion_factor", f32);
}

fn on_setting_change_set_uniform(
    self: *Self,
    setting: []const u8,
    comptime pass_name: []const u8,
    comptime uniform: [:0]const u8,
    comptime T: type,
) !void {
    const evt = try App.settings().settings_change_event(T, setting);
    try App.ecs().add_event_listener(self.eid, T, *Self, evt, self, &(struct {
        fn callback(this: *Self, vals: []T) void {
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
    self.seen_cnt = try self.compute_seen();
    if (self.seen_cnt == 0) return;

    try self.shader.set_mat4("u_view", App.game_state().camera.view_mat());
    try self.shader.set_mat4("u_proj", App.game_state().camera.proj_mat());

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.MultiDrawElementsIndirect(
        gl.TRIANGLES,
        @field(gl, BlockModel.index_type),
        0,
        @intCast(self.seen_cnt),
        0,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));
    try gl_call(gl.BindVertexArray(0));
}

pub fn upload_chunk(self: *Self, chunk: *Chunk) !void {
    if (self.meshes.get(chunk.coords)) |mesh| {
        try mesh.build();
        try self.update_mesh(mesh);
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

pub fn on_frame_start(self: *Self) !void {
    try App.gui().add_to_frame(Self, "Debug", self, struct {
        fn callback(this: *Self) !void {
            c.igText("Triangles: %zu", this.triangle_count);
            c.igText("Displayed chunks: %zu", this.seen_cnt);
            const gpu_mem_faces: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
                App.frame_alloc(),
                "GPU Memory (faces): {f}",
                .{util.MemoryUsage.from_bytes(this.faces.size)},
                0,
            ));
            c.igText("%s", gpu_mem_faces);
            const gpu_mem_indirect: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
                App.frame_alloc(),
                "GPU Memory (indirect+coords): {f}",
                .{util.MemoryUsage.from_bytes(
                    this.allocated_chunks_count * (@sizeOf(Indirect) + 4 * @sizeOf(i32)),
                )},
                0,
            ));
            c.igText("%s", gpu_mem_indirect);
        }
    }.callback, @src());
}

const raw_faces: []const u8 = blk: {
    @setEvalBranchQuota(std.math.maxInt(u32));
    var normals_data = std.mem.zeroes([4 * BLOCK_FACE_COUNT]f32);
    for (BlockModel.normals, 0..) |normal, i| {
        normals_data[4 * i + 0] = normal[0];
        normals_data[4 * i + 1] = normal[1];
        normals_data[4 * i + 2] = normal[2];
    }
    const size = 4 * BLOCK_FACE_COUNT * VERTS_PER_FACE * World.CHUNK_SIZE * World.CHUNK_SIZE;
    var faces_data = std.mem.zeroes([size]f32);
    for (BlockModel.faces, 0..) |face, n| {
        for (0..World.CHUNK_SIZE) |w| {
            for (0..World.CHUNK_SIZE) |h| {
                for (face, 0..) |vertex, p| {
                    const idx = n * N_OFFSET + w * W_OFFSET + h * H_OFFSET + p * P_OFFSET;
                    const vec: zm.Vec3f = vertex;
                    var scale = World.BlockCoords{ .x = 1, .y = 1, .z = 1 };
                    @field(scale, BlockModel.scale[n][0..1]) = w + 1;
                    @field(scale, BlockModel.scale[n][1..2]) = h + 1;
                    faces_data[4 * idx + 0] = vec[0] * scale.x;
                    faces_data[4 * idx + 1] = vec[1] * scale.y;
                    faces_data[4 * idx + 2] = vec[2] * scale.z;
                }
            }
        }
    }

    break :blk @ptrCast(&(normals_data ++ faces_data));
};

fn init_buffers(self: *Self) !void {
    self.allocated_chunks_count = EXPECTED_LOADED_CHUNKS_COUNT;
    self.faces = try .init(App.gpa(), EXPECTED_BUFFER_SIZE, gl.STREAM_DRAW);

    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_model_ibo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.block_model_ubo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buffer)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.chunk_coords_ssbo)));

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buffer));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        @intCast(self.allocated_chunks_count * @sizeOf(Indirect)),
        null,
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_coords_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(self.allocated_chunks_count * @sizeOf(u32) * 4),
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

    try gl_call(gl.BindVertexBuffer(VERT_DATA_BINDING, self.faces.buffer, 0, @sizeOf(VertexData)));

    try gl_call(gl.EnableVertexAttribArray(VERT_DATA_LOCATION_A));
    try gl_call(gl.VertexAttribIFormat(VERT_DATA_LOCATION_A, 1, gl.UNSIGNED_INT, 4));
    try gl_call(gl.VertexAttribBinding(VERT_DATA_LOCATION_A, VERT_DATA_BINDING));

    try gl_call(gl.EnableVertexAttribArray(VERT_DATA_LOCATION_B));
    try gl_call(gl.VertexAttribIFormat(VERT_DATA_LOCATION_B, 1, gl.UNSIGNED_INT, 0));
    try gl_call(gl.VertexAttribBinding(VERT_DATA_LOCATION_B, VERT_DATA_BINDING));

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

const MeshOrder = struct {
    mesh: *ChunkMesh,
    center: zm.Vec3f,

    fn less(pos: zm.Vec3f, a: MeshOrder, b: MeshOrder) bool {
        const d1 = zm.vec.lenSq(a.center - pos);
        const d2 = zm.vec.lenSq(b.center - pos);
        return d1 < d2;
    }
};

fn compute_seen(self: *Self) !usize {
    const do_frustum_culling = App.settings().get_value(bool, ".main.renderer.frustum_culling").?;
    const do_occlusion_culling = App.settings().get_value(bool, ".main.renderer.occlusion_culling").?;

    const seen_meshes = try App.frame_alloc().alloc(MeshOrder, self.meshes.count());
    const cam: *Camera = &App.game_state().camera;

    var seen_count: usize = 0;
    for (self.meshes.values()) |mesh| {
        const sphere = mesh.bounding_sphere();
        const center = zm.vec.xyz(sphere);
        if (do_frustum_culling and !cam.sphere_in_frustum(center, sphere[3])) continue;

        seen_meshes[seen_count].mesh = mesh;
        seen_meshes[seen_count].center = center;
        seen_count += 1;
    }
    if (seen_count == 0) return 0;

    const in_frustum = seen_meshes[0..seen_count];
    std.mem.sort(MeshOrder, in_frustum, cam.frustum_for_occlusion.pos, MeshOrder.less);

    if (do_occlusion_culling) {
        seen_count = 0;
        for (in_frustum) |mesh| {
            const chunk = mesh.mesh.chunk.?;
            if (cam.is_occluded(chunk.aabb())) continue;
            if (chunk.get_occluder()) |aabb| {
                cam.add_occluder(aabb);
            }

            seen_meshes[seen_count] = mesh;
            seen_count += 1;
        }

        // Log.log(.debug, "occlusion: {f}", .{util.Array2DFormat(f32).init(
        //     cam.occlusion.grid.items,
        //     cam.occlusion.w,
        //     cam.occlusion.h,
        // )});
        // Log.log(.debug, "", .{});
    }

    const indirect = try App.frame_alloc().alloc(Indirect, seen_count);
    const coords = try App.frame_alloc().alloc(i32, 4 * seen_count);
    @memset(coords, 0);
    @memset(indirect, std.mem.zeroes(Indirect));

    self.triangle_count = 0;
    for (0..seen_count) |i| {
        const mesh = seen_meshes[i].mesh;
        const range = self.faces.get_range(mesh.handle).?;
        indirect[i] = Indirect{
            .count = 6,
            .instance_count = @intCast(mesh.faces.items.len),
            .base_instance = @intCast(@divExact(range.offset, @sizeOf(VertexData))),
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

    if (self.allocated_chunks_count < seen_count) {
        self.allocated_chunks_count = seen_count * 2;
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
        @intCast(seen_count * @sizeOf(i32) * 4),
        @ptrCast(coords),
    ));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    try gl_call(gl.BufferSubData(
        gl.DRAW_INDIRECT_BUFFER,
        0,
        @intCast(seen_count * @sizeOf(Indirect)),
        @ptrCast(indirect),
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindVertexBuffer(VERT_DATA_BINDING, self.faces.buffer, 0, @sizeOf(VertexData)));
    try gl_call(gl.BindVertexArray(0));

    return seen_count;
}

const ChunkMesh = struct {
    const X_OFFSET = Chunk.X_OFFSET;
    const Y_OFFSET = Chunk.Y_OFFSET;
    const Z_OFFSET = Chunk.Z_OFFSET;

    chunk: ?*Chunk,
    faces: std.ArrayListUnmanaged(VertexData),
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
        self.faces.clearRetainingCapacity();
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
    fn pack(self: *ChunkMesh, pos: World.BlockCoords, size: FaceSize, face: World.BlockFace, occlusion: u4) VertexData {
        var data_a: u32 = 0;
        const x, const y, const z = .{ pos.x, pos.y, pos.z };
        const w, const h = .{ size.w, size.h };

        data_a |= @as(u32, @intCast(x)) << 28;
        data_a |= @as(u32, @intCast(y)) << 24;
        data_a |= @as(u32, @intCast(z)) << 20;
        data_a |= @as(u32, @intFromEnum(face)) << 16;
        data_a |= @as(u32, @intCast(w - 1)) << 12;
        data_a |= @as(u32, @intCast(h - 1)) << 8;
        data_a |= @as(u32, @intFromEnum(self.get(pos)));

        var data_b: u32 = 0;
        data_b |= @as(u32, occlusion) << 28;

        return @as(VertexData, @intCast(data_a)) << 32 | @as(VertexData, @intCast(data_b));
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

    const occlusion_mask: [BLOCK_FACE_COUNT][4]u4 = .{
        .{ 0b0010, 0b0001, 0b1000, 0b0100 }, // front
        .{ 0b0010, 0b0001, 0b0100, 0b1000 }, // back
        .{ 0b0010, 0b0001, 0b0100, 0b1000 }, // right
        .{ 0b0010, 0b0001, 0b1000, 0b0100 }, // left
        .{ 0b0001, 0b0010, 0b1000, 0b0100 }, // top
        .{ 0b0001, 0b0010, 0b0100, 0b1000 }, // bot
    };

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

                // const size = if (Options.greedy_meshing)
                //     self.greedy_size(pos, face, &visited)
                // else
                const size = self.one_by_one_size(pos, face, &visited);
                const world_pos = World.world_coords(self.chunk.?.coords, pos);

                var occlusion: u4 = 0;
                const front = face.next_to(world_pos);

                var below = front;
                @field(below, h_dim) -= 1;
                if ((self.get_at_world(below) orelse .air) != .air) {
                    occlusion |= occlusion_mask[@intFromEnum(face)][0];
                }
                var above = front;
                @field(above, h_dim) += 1;
                if ((self.get_at_world(above) orelse .air) != .air) {
                    occlusion |= occlusion_mask[@intFromEnum(face)][1];
                }
                var left = front;
                @field(left, w_dim) -= 1;
                if ((self.get_at_world(left) orelse .air) != .air) {
                    occlusion |= occlusion_mask[@intFromEnum(face)][2];
                }
                var right = front;
                @field(right, w_dim) += 1;
                if ((self.get_at_world(right) orelse .air) != .air) {
                    occlusion |= occlusion_mask[@intFromEnum(face)][3];
                }

                try self.faces.append(App.gpa(), self.pack(pos, size, face, occlusion));
            }
        }
    }
    fn get_at_world(self: *ChunkMesh, world_pos: World.WorldCoords) ?World.BlockId {
        const chunk = World.world_to_chunk(world_pos);
        if (!std.meta.eql(chunk, self.chunk.?.coords)) return null;
        return self.chunk.?.get(World.world_to_block(world_pos));
    }

    fn one_by_one_size(
        self: *ChunkMesh,
        origin: World.BlockCoords,
        comptime face: World.BlockFace,
        visited: *[CHUNK_SIZE][CHUNK_SIZE]bool,
    ) FaceSize {
        _ = visited;
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

    fn corners(self: *ChunkMesh) [8]zm.Vec3f {
        var pts = std.mem.zeroes([8]zm.Vec3f);
        const origin = zm.Vec3f{
            @as(f32, @floatFromInt(self.chunk.?.coords.x)) * CHUNK_SIZE,
            @as(f32, @floatFromInt(self.chunk.?.coords.y)) * CHUNK_SIZE,
            @as(f32, @floatFromInt(self.chunk.?.coords.z)) * CHUNK_SIZE,
        };
        var idx: usize = 0;
        for (0..2) |i| {
            for (0..2) |j| {
                for (0..2) |k| {
                    const d = zm.Vec3f{
                        @as(f32, @floatFromInt(i)),
                        @as(f32, @floatFromInt(j)),
                        @as(f32, @floatFromInt(k)),
                    };
                    pts[idx] = @mulAdd(zm.Vec3f, d, @splat(CHUNK_SIZE), origin);
                    idx += 1;
                }
            }
        }
        return pts;
    }
    //xyzr
    fn bounding_sphere(self: *ChunkMesh) zm.Vec4f {
        var center: zm.Vec3f = @splat(0);
        for (self.corners()) |p| center += p;
        center /= @splat(8);
        return .{ center[0], center[1], center[2], 8 * @sqrt(3.0) };
    }

    fn next_to(pos: World.BlockCoords, dir: World.BlockFace) ?World.BlockCoords {
        switch (dir) {
            .front => if (pos.z + 1 < CHUNK_SIZE) return .{ .x = pos.x, .y = pos.y, .z = pos.z + 1 },
            .right => if (pos.x + 1 < CHUNK_SIZE) return .{ .x = pos.x + 1, .y = pos.y, .z = pos.z },
            .up => if (pos.y + 1 < CHUNK_SIZE) return .{ .x = pos.x, .y = pos.y + 1, .z = pos.z },
            .back => if (pos.z > 0) return .{ .x = pos.x, .y = pos.y, .z = pos.z - 1 },
            .left => if (pos.x > 0) return .{ .x = pos.x - 1, .y = pos.y, .z = pos.z },
            .bot => if (pos.y > 0) return .{ .x = pos.x, .y = pos.y - 1, .z = pos.z },
        }
        return null;
    }
};

fn update_mesh(self: *Self, mesh: *ChunkMesh) !void {
    const actual_size = mesh.faces.items.len * @sizeOf(VertexData);
    const requested_size = @max(MINIMAL_MESH_SIZE, actual_size);
    if (mesh.handle == .invalid) {
        mesh.handle = try self.faces.alloc(requested_size, .@"4");
    } else {
        const range = self.faces.get_range(mesh.handle).?;
        try gl_call(gl.InvalidateBufferSubData(self.faces.buffer, range.offset, range.size));
        mesh.handle = try self.faces.realloc(mesh.handle, requested_size);
    }
    if (actual_size == 0) {
        return;
    }

    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.faces.buffer));
    const range = self.faces.get_range(mesh.handle).?;
    try gl_call(gl.BufferSubData(
        gl.ARRAY_BUFFER,
        range.offset,
        range.size,
        mesh.faces.items.ptr,
    ));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
}
