const std = @import("std");
const App = @import("../App.zig");
const Game = @import("../Game.zig");
const Chunk = @import("Chunk.zig");
const World = @import("../World.zig");
const SsboBindings = @import("../SsboBindings.zig");
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
const LightLevelInfo = Renderer.LightLevelInfo;
const LightList = Renderer.LightList;

const logger = std.log.scoped(.block_renderer);

const BlockRenderer = @This();

const CHUNK_SIZE = Chunk.CHUNK_SIZE;
const ChunkData = Renderer.ChunkData;

const DEFAULT_FACES_SIZE = 1024 * 1024 * 16;
const DEFAULT_LIGHT_LEVELS_SIZE = 1024 * 1024;
const DEFAULT_LIGHT_LISTS_SIZE = 1024 * 1024;
const DEFAULT_CHUNK_DATA_SIZE = 1024 * @sizeOf(ChunkData);
const DEFAULT_INDIRECT_SIZE = 1024 * @sizeOf(Indirect);
const DEFAULT_CHUNK_INDICES_SIZE = 1024;
const BLOCK_ATLAS_TEX = 0;

world: *World,

block_pass: Shader,
block_vao: gl.uint,
block_ibo: gl.uint,
model_ssbo: gl.uint,
normal_ubo: gl.uint,

faces: GpuAlloc,
light_levels: GpuAlloc,
light_lists: GpuAlloc,

had_realloc: bool,
chunk_data_ssbo: gl.uint,
draw_id_to_chunk_ssbo: gl.uint,
indirect_buf: gl.uint,

drawn_chunks_cnt: usize,
shown_triangle_count: usize,
total_triangle_count: usize,

chunks_with_meshes_or_lights: std.AutoArrayHashMapUnmanaged(*Chunk, void) = .empty,

const CoordsHash = struct {
    pub fn hash(_: CoordsHash, x: Coords) u32 {
        const y: @Vector(3, u32) = @bitCast(x);
        const z: @Vector(3, u8) = @truncate(y);
        const w: u32 = @intCast(@as(u24, @bitCast(z)));
        return std.hash.int(w);
    }

    pub fn eql(_: CoordsHash, x: Coords, y: Coords, _: usize) bool {
        return @reduce(.And, x == y);
    }
};

pub fn init(world: *World) !*BlockRenderer {
    const self = try App.gpa().create(BlockRenderer);
    self.world = world;

    logger.debug("{*} Initializing...", .{self});

    self.had_realloc = false;
    self.drawn_chunks_cnt = 0;
    self.shown_triangle_count = 0;
    self.total_triangle_count = 0;
    self.chunks_with_meshes_or_lights = .empty;

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
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.draw_id_to_chunk_ssbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.indirect_buf)));
    self.faces = try .init(App.static_alloc(), DEFAULT_FACES_SIZE, gl.STREAM_DRAW);
    self.light_levels = try .init(
        App.static_alloc(),
        DEFAULT_LIGHT_LEVELS_SIZE,
        gl.STREAM_DRAW,
    );
    self.light_lists = try .init(
        App.static_alloc(),
        DEFAULT_LIGHT_LISTS_SIZE,
        gl.STREAM_DRAW,
    );

    try gl_call(gl.BindVertexArray(self.block_vao));

    try self.init_models();
    logger.debug("{*} Initialized block model", .{self});
    try self.init_face_attribs();
    logger.debug("{*} Initialized face data buffers", .{self});
    try self.init_chunk_data();
    logger.debug("{*} Initialized chunk data buffers", .{self});

    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.LIGHT_LISTS,
        self.light_lists.buffer,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.LIGHT_LEVELS,
        self.light_levels.buffer,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.DRAW_ID_TO_CHUNK,
        self.draw_id_to_chunk_ssbo,
    ));

    try gl_call(gl.BindVertexArray(0));
    try gl_call(gl.BindBuffer(gl.UNIFORM_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try self.block_pass.observe_settings(
        ".main.renderer.face_ao",
        bool,
        "u_enable_face_ao",
        @src(),
    );
    try self.block_pass.observe_settings(
        ".main.renderer.face_ao_factor",
        f32,
        "u_ao_factor",
        @src(),
    );

    inline for (Ao.from_idx, 0..) |ao, i| {
        const uni: [:0]const u8 = std.fmt.comptimePrint("u_idx_to_ao[{}]", .{i});
        try self.block_pass.set_uint(uni, @intCast(ao));
    }

    logger.debug("{*} Finished initializing...", .{self});

    return self;
}

fn init_models(self: *BlockRenderer) !void {
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
    try gl_call(gl.BindBufferBase(gl.UNIFORM_BUFFER, SsboBindings.NORMAL, self.normal_ubo));

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
        SsboBindings.FACE_MODEL,
        self.model_ssbo,
    ));
}

fn init_face_attribs(self: *BlockRenderer) !void {
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

fn init_chunk_data(self: *BlockRenderer) !void {
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.draw_id_to_chunk_ssbo));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_data_ssbo));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.CHUNK_DATA,
        self.chunk_data_ssbo,
    ));

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));
}

pub fn deinit(self: *BlockRenderer) void {
    self.block_pass.deinit();
    self.faces.deinit();
    self.light_lists.deinit();
    self.light_levels.deinit();
    self.chunks_with_meshes_or_lights.deinit(App.gpa());

    gl.DeleteVertexArrays(1, @ptrCast(&self.block_vao));
    gl.DeleteBuffers(1, @ptrCast(&self.block_ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.normal_ubo));
    gl.DeleteBuffers(1, @ptrCast(&self.model_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.chunk_data_ssbo));
    gl.DeleteBuffers(1, @ptrCast(&self.indirect_buf));
    gl.DeleteBuffers(1, @ptrCast(&self.draw_id_to_chunk_ssbo));

    App.gpa().destroy(self);
}

pub fn draw(self: *BlockRenderer, cam: *Camera) (OOM || GlError)!void {
    try gl_call(gl.BindVertexArray(self.block_vao));
    try gl_call(gl.BindVertexBuffer(
        FACE_DATA_BINDING,
        self.faces.buffer,
        0,
        @sizeOf(FaceMesh),
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.LIGHT_LISTS,
        self.light_lists.buffer,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        SsboBindings.LIGHT_LEVELS,
        self.light_levels.buffer,
    ));

    const draw_count = try self.compute_drawn_chunk_data(cam);

    try self.block_pass.set_mat4("u_view", cam.view_mat());
    try self.block_pass.set_mat4("u_proj", cam.proj_mat());
    try self.block_pass.bind();

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

pub fn upload_chunk_lights(self: *BlockRenderer, chunk: *Chunk) !void {
    if (chunk.light_levels_handle != .invalid) {
        const old_range = self.light_levels.get_range(chunk.light_levels_handle).?;
        const new_size = chunk.compiled_light_levels.items.len * @sizeOf(LightLevelInfo);
        try gl_call(gl.InvalidateBufferSubData(
            self.light_levels.buffer,
            old_range.offset,
            old_range.size,
        ));
        chunk.light_levels_handle = try self.light_levels.realloc(
            chunk.light_levels_handle,
            new_size,
            std.mem.Alignment.of(LightLevelInfo),
        );
    } else {
        chunk.light_levels_handle = try self.light_levels.alloc(
            chunk.compiled_light_levels.items.len * @sizeOf(LightLevelInfo),
            std.mem.Alignment.of(LightLevelInfo),
        );
    }

    if (chunk.light_lists_handle != .invalid) {
        const old_range = self.light_lists.get_range(chunk.light_lists_handle).?;
        const new_size = chunk.compiled_light_lists.items.len * @sizeOf(LightList);
        try gl_call(gl.InvalidateBufferSubData(
            self.light_lists.buffer,
            old_range.offset,
            old_range.size,
        ));
        chunk.light_lists_handle = try self.light_lists.realloc(
            chunk.light_lists_handle,
            new_size,
            std.mem.Alignment.of(LightList),
        );
    } else {
        chunk.light_lists_handle = try self.light_lists.alloc(
            chunk.compiled_light_lists.items.len * @sizeOf(LightList),
            std.mem.Alignment.of(LightList),
        );
    }

    {
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.light_levels.buffer));
        const range = self.light_levels.get_range(chunk.light_levels_handle).?;
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            range.offset,
            range.size,
            @ptrCast(chunk.compiled_light_levels.items),
        ));
    }

    {
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.light_lists.buffer));
        const range = self.light_lists.get_range(chunk.light_lists_handle).?;
        try gl_call(gl.BufferSubData(
            gl.ARRAY_BUFFER,
            range.offset,
            range.size,
            @ptrCast(chunk.compiled_light_lists.items),
        ));
    }
    try self.chunks_with_meshes_or_lights.put(App.gpa(), chunk, {});
}

pub fn upload_chunk_mesh(self: *BlockRenderer, chunk: *Chunk) !void {
    logger.debug("{*}: upload_chunk_mesh({*}@{})", .{ self, chunk, chunk.coords });

    for (
        &chunk.face_handles.values,
        &chunk.faces.values,
        &chunk.uploaded_face_lengths.values,
    ) |*handle, faces, *cnt| {
        if (handle.* != .invalid) {
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
        } else {
            const new_size = faces.items.len * @sizeOf(FaceMesh);
            handle.* = try self.faces.alloc(
                new_size,
                std.mem.Alignment.of(FaceMesh),
            );
        }

        cnt.* = faces.items.len;
        self.total_triangle_count += faces.items.len * 2;

        const range = self.faces.get_range(handle.*).?;
        logger.debug(
            "{*}: chunk {}: handle={}, offset={d}, size={d}",
            .{ self, chunk.coords, handle, range.offset, range.size },
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
    try self.chunks_with_meshes_or_lights.put(App.gpa(), chunk, {});
}

pub fn destroy_chunk_mesh_and_lights(self: *BlockRenderer, chunk: *Chunk) !void {
    for (&chunk.face_handles.values, &chunk.uploaded_face_lengths.values) |*handle, cnt| {
        if (handle.* == .invalid) continue;
        self.total_triangle_count -= cnt * 2;
        self.faces.free(handle.*);
        handle.* = .invalid;
    }

    if (chunk.light_levels_handle != .invalid) {
        self.light_levels.free(chunk.light_levels_handle);
        chunk.light_levels_handle = .invalid;
    }

    if (chunk.light_lists_handle != .invalid) {
        self.light_lists.free(chunk.light_lists_handle);
        chunk.light_lists_handle = .invalid;
    }

    _ = self.chunks_with_meshes_or_lights.swapRemove(chunk);
}

fn on_imgui(self: *BlockRenderer) !void {
    const gpu_mem_faces: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        \\Meshes: 
        \\    drawn:     {d}
        \\    triangles: {d}/{d}
        \\GPU Memory:
        \\    faces:      {Bi:.2}
        \\    lights:     {Bi:.2}+{Bi:.2}
    ,
        .{
            self.drawn_chunks_cnt,
            self.shown_triangle_count,
            self.total_triangle_count,
            self.faces.size,
            self.light_levels.size,
            self.light_lists.size,
        },
        0,
    ));
    c.igText("%s", gpu_mem_faces);
}

pub fn on_frame_start(self: *BlockRenderer) !void {
    try App.gui().add_to_frame(BlockRenderer, "Debug", self, on_imgui, @src());
}

fn compute_drawn_chunk_data(self: *BlockRenderer, cam: *Camera) !usize {
    const do_frustum_culling = App.settings().get_value(
        bool,
        ".main.renderer.frustum_culling",
    );
    const do_occlusion_culling = App.settings().get_value(
        bool,
        ".main.renderer.occlusion_culling",
    );

    const center, const radius = self.world.currently_loaded_region();
    const one: Coords = @splat(1);
    const two: Coords = @splat(2);
    const size: @Vector(3, usize) = @intCast(radius * two + one);
    const stride: @Vector(3, usize) = .{ size[1] * size[2], size[2], 1 };
    const n = @reduce(.Mul, size);
    std.debug.assert(radius[0] == radius[2]);

    var indirect = std.ArrayList(Indirect).empty;
    try indirect.ensureTotalCapacity(
        App.frame_alloc(),
        6 * self.chunks_with_meshes_or_lights.count(),
    );
    var draw_order = std.ArrayList(usize).empty;
    try draw_order.ensureTotalCapacity(App.frame_alloc(), n);
    var chunks = std.ArrayList(ChunkData).empty;
    try chunks.resize(App.frame_alloc(), n);
    var draw_id_to_chunk_idx = std.ArrayList(u32).empty;

    const cam_chunk = cam.chunk_coords();
    self.shown_triangle_count = 0;
    outer: for (self.chunks_with_meshes_or_lights.keys()) |chunk| {
        const delta = chunk.coords - center;
        std.debug.assert(@reduce(.And, radius + delta >= Coords{ 0, 0, 0 }));
        const chunk_idx: usize = @reduce(
            .Add,
            @as(@Vector(3, usize), @intCast(radius + delta)) * stride,
        );

        const chunk_data = &chunks.items[chunk_idx];
        chunk_data.* = ChunkData{
            .x = chunk.coords[0],
            .y = chunk.coords[1],
            .z = chunk.coords[2],
            .light_levels = 0,
            .light_lists = 0,
        };

        if (chunk.light_levels_handle != .invalid) {
            std.debug.assert(chunk.light_lists_handle != .invalid);

            const light_levels_range = self.light_levels
                .get_range(chunk.light_levels_handle).?;
            const light_lists_range = self.light_lists
                .get_range(chunk.light_lists_handle).?;
            const light_levels: u32 = @intCast(@divExact(
                light_levels_range.offset,
                @sizeOf(LightLevelInfo),
            ));
            const light_lists: u32 = @intCast(@divExact(
                light_lists_range.offset,
                @sizeOf(LightList),
            ));

            chunk_data.light_levels = light_levels;
            chunk_data.light_lists = light_lists;
            chunk_data.no_lights = @intFromBool(light_levels_range.size == 0);
        }

        if (do_occlusion_culling and
            !@reduce(.And, cam_chunk == chunk.coords) and
            chunk.is_occluded)
            continue;

        const bound = bounding_sphere(chunk.coords);
        if (do_frustum_culling and !cam.sphere_in_frustum(zm.vec.xyz(bound), bound[3]))
            continue;

        var had_iters = false;
        for (&chunk.face_handles.values, &chunk.uploaded_face_lengths.values) |handle, cnt| {
            if (handle == .invalid) {
                std.debug.assert(!had_iters);
                continue :outer;
            }
            had_iters = true;

            const range = self.faces.get_range(handle).?;
            indirect.appendAssumeCapacity(Indirect{
                .count = 6,
                .instance_count = @intCast(cnt),
                .base_instance = @intCast(@divExact(range.offset, @sizeOf(FaceMesh))),
                .base_vertex = 0,
                .first_index = 0,
            });

            self.shown_triangle_count += cnt * 2;
        }

        try draw_id_to_chunk_idx.append(App.frame_alloc(), @intCast(chunk_idx));
    }

    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, self.indirect_buf));
    try gl_call(gl.BufferData(
        gl.DRAW_INDIRECT_BUFFER,
        @intCast(indirect.items.len * @sizeOf(Indirect)),
        @ptrCast(indirect.items),
        gl.STREAM_DRAW,
    ));
    try gl_call(gl.BindBuffer(gl.DRAW_INDIRECT_BUFFER, 0));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.chunk_data_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(chunks.items.len * @sizeOf(ChunkData)),
        @ptrCast(chunks.items),
        gl.STREAM_DRAW,
    ));

    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.draw_id_to_chunk_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(draw_id_to_chunk_idx.items.len * @sizeOf(u32)),
        @ptrCast(draw_id_to_chunk_idx.items),
        gl.STREAM_DRAW,
    ));

    self.drawn_chunks_cnt = indirect.items.len / 6;
    std.debug.assert(indirect.items.len / 6 == draw_id_to_chunk_idx.items.len);
    return indirect.items.len;
}

fn ring_order(arena: std.mem.Allocator, width: usize, height: usize) ![]const Coords {
    var res = std.ArrayList(Coords).empty;
    const size = (width * 2 + 1) * (width * 2 + 1) * (height * 2 + 1);
    try res.ensureTotalCapacity(arena, size);

    for (0..width + 1) |ring| {
        const side = ring * 2;

        for (0..2 * height + 1) |j| {
            const y: i32 = if (j % 2 == 0)
                @intCast((j + 1) / 2)
            else
                -@as(i32, @intCast((j + 1) / 2));

            if (ring == 0) {
                res.appendAssumeCapacity(.{ 0, y, 0 });
                continue;
            }

            for (0..side) |i| {
                const x: i32 = if (i % 2 == 0)
                    @intCast((i + 1) / 2)
                else
                    -@as(i32, @intCast((i + 1) / 2));

                const z: i32 = @intCast(ring);
                res.appendAssumeCapacity(.{ x, y, z });
                res.appendAssumeCapacity(.{ -x, y, -z });
                res.appendAssumeCapacity(.{ -z, y, x });
                res.appendAssumeCapacity(.{ z, y, -x });
            }
        }
    }

    return try res.toOwnedSlice(arena);
}

test "ring order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (0..10) |h| {
        for (0..10) |w| {
            errdefer logger.err("on test w={},h={}", .{ w, h });

            const size = (w * 2 + 1) * (w * 2 + 1) * (h * 2 + 1);
            var set = std.AutoArrayHashMapUnmanaged(Coords, usize).empty;
            const ord = try ring_order(arena.allocator(), w, h);

            errdefer logger.err("ord={any}", .{ord});
            try std.testing.expectEqual(size, ord.len);

            for (ord, 0..) |pos, i| {
                errdefer logger.err("on pos={},i={}", .{ pos, i });

                const entry = try set.getOrPutValue(arena.allocator(), pos, i);
                try std.testing.expect(!entry.found_existing);
            }
            try std.testing.expectEqual(size, set.count());

            _ = arena.reset(.retain_capacity);
        }
    }
}

const Indirect = extern struct {
    count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    base_instance: u32,
};

fn bounding_sphere(coords: Coords) zm.Vec4f {
    const size: zm.Vec3f = @splat(CHUNK_SIZE);
    const center: zm.Vec3f = @floatFromInt(coords);
    const pos = center * size + size * @as(zm.Vec3f, @splat(0.5));
    const rad: f32 = comptime @as(f32, @floatFromInt(CHUNK_SIZE)) * @sqrt(3.0) / 2.0;

    return .{ pos[0], pos[1], pos[2], rad };
}

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
const BLOCK_FACE_CNT = std.enums.values(Block.Direction).len;

const block_vert =
    \\#version 460 core
    \\
++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_A {d}", .{FACE_DATA_LOCATION_A}) ++
    std.fmt.comptimePrint("\n#define FACE_DATA_LOCATION_B {d}", .{FACE_DATA_LOCATION_B}) ++
    std.fmt.comptimePrint("\n#define CHUNK_DATA_BINDING {d}", .{SsboBindings.CHUNK_DATA}) ++
    std.fmt.comptimePrint("\n#define NORMAL_BINDING {d}", .{SsboBindings.NORMAL}) ++
    std.fmt.comptimePrint("\n#define MODEL_BINDING {d}", .{SsboBindings.FACE_MODEL}) ++
    std.fmt.comptimePrint("\n#define DRAW_ID_TO_CHUNK_BINDING {d}", .{SsboBindings.DRAW_ID_TO_CHUNK}) ++
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
++ std.fmt.comptimePrint("uniform uint u_idx_to_ao[{}];\n", .{Ao.from_idx.len}) ++
    ChunkData.define() ++
    \\
    \\layout (std430, binding = CHUNK_DATA_BINDING) readonly buffer ChunkData{
    \\  Chunk chunks[];
    \\};
    \\
    \\layout (std430, binding = MODEL_BINDING) readonly buffer Models {
    \\  uint raw_model[];
    \\};
    \\
    \\layout (std430, binding = DRAW_ID_TO_CHUNK_BINDING) readonly buffer DrawIdToChunk {
    \\  uint draw_id_to_chunk[];
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
    \\uniform vec2 uvs[4] = {vec2(0,0), vec2(0,1), vec2(1,1), vec2(1,0)};
    \\
    \\out vec3 frag_norm;
    \\out uint frag_ao;
    \\out uint frag_tex;
    \\out vec2 frag_uv;
    \\out vec4 frag_pos;
    \\out vec3 frag_color;
    \\
    \\void main() {
    \\  Face face = unpack_face();
    \\  Model model = unpack_model(face.model);
    \\  Chunk chunk = chunks[draw_id_to_chunk[gl_DrawID / BLOCK_FACE_CNT]];
    \\
    \\  uint p = gl_VertexID;
    \\  vec3 normal = normals[gl_DrawID % BLOCK_FACE_CNT];
    \\  frag_uv = uvs[p] * model.scale + model.offset.xy;
    \\  vec3 vert = norm_to_world[gl_DrawID % BLOCK_FACE_CNT] * 
    \\    vec3(frag_uv - vec2(0.5, 0.5), 0.5 - model.offset.z) + face.pos + vec3(0.5,0.5,0.5);
    \\  vec3 chunk_coords = vec3(chunk.x, chunk.y, chunk.z);
    \\  vec4 world_pos = vec4(vert + chunk_coords * 16, 1);
    \\  vec4 view_pos = u_view * world_pos;
    \\  gl_Position = u_proj * view_pos;
    \\
    \\  frag_norm = normal;
    \\  frag_ao = u_idx_to_ao[face.ao];
    \\  frag_tex = face.texture;
    \\  frag_pos = vec4(world_pos.xyz, 1.0);
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
    \\in vec4 frag_pos;
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
    \\  out_pos = frag_pos;
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

    pub fn init(pos: Coords, texture: usize, model: usize, ao: [8]bool) FaceMesh {
        const Tuple = std.meta.Tuple(&(.{u8} ** 8));
        var tuple: Tuple = undefined;
        inline for (tuple, 0..) |_, i| tuple[i] = @intFromBool(ao[i]);

        return .{
            .x = @intCast(pos[0]),
            .y = @intCast(pos[1]),
            .z = @intCast(pos[2]),
            .model = @intCast(model),
            .texture = @intCast(texture),
            .ao = Ao.to_idx[@call(.auto, Ao.pack, tuple)],
        };
    }
};

pub const Ao = struct {
    const to_idx = precalculated[1];
    pub const from_idx = precalculated[0];

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
        var from_ao: [256]u6 = @splat(0);

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
            from_ao[x] = @intCast(k);
        }
        std.debug.assert(i == UNIQUE_CNT);
        break :blk .{ to_ao, from_ao };
    };
};
