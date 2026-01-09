const std = @import("std");
const zm = @import("zm");
const gl = @import("gl");
const VFS = @import("VFS.zig");
const gl_call = @import("../util.zig").gl_call;
const Shader = @import("../Shader.zig");
const GameCamera = @import("../Camera.zig");

const glTF = @This();
const logger = std.log.scoped(.gltf);
const Renderer = @import("../Renderer.zig");

arena: std.heap.ArenaAllocator,

primitives: []PrimitiveMesh = &.{},
nodes_ssbo: gl.uint = 0,
mesh_parents_vbo: gl.uint = 0,
buffers: []gl.uint = &.{},
shader: Shader = undefined,

instances: std.ArrayList(InstanceData) = .empty,
free_instances: std.ArrayList(usize) = .empty,
instance_ssbo_capacity: usize = 0,
instance_ssbo: gl.uint = 0,
updated: bool = false,

pub fn init(gpa: std.mem.Allocator, file: *VFS.File) !*glTF {
    var parser = try Parser.init(gpa, file);
    defer parser.arena.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const self = try arena.allocator().create(glTF);
    self.* = glTF{ .arena = arena };

    var src: [2]Shader.Source = .{
        Shader.Source{ .name = "vert", .sources = &.{vert}, .kind = gl.VERTEX_SHADER },
        Shader.Source{ .name = "frag", .sources = &.{frag}, .kind = gl.FRAGMENT_SHADER },
    };
    self.shader = try .init(&src, "gltf_pass");
    try self.upload(&parser);

    return self;
}

pub fn deinit(self: *glTF) void {
    gl.DeleteBuffers(@intCast(self.buffers.len), @ptrCast(self.buffers));
    gl.DeleteBuffers(1, @ptrCast(&self.mesh_parents_vbo));
    gl.DeleteBuffers(1, @ptrCast(&self.instance_ssbo));

    for (self.primitives) |*p| p.deinit();

    self.shader.deinit();
    self.arena.deinit();
}

pub fn draw(self: *glTF, cam: *GameCamera) !void {
    if (self.instances.items.len == 0) return;

    if (self.updated) {
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.instance_ssbo));
        try gl_call(gl.BufferSubData(
            gl.SHADER_STORAGE_BUFFER,
            0,
            @intCast(self.instances.items.len * @sizeOf(InstanceData)),
            @ptrCast(self.instances.items),
        ));
        self.updated = false;
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));
    }

    try self.shader.bind();
    try self.shader.set_mat4("u_view", cam.view_mat());
    try self.shader.set_mat4("u_proj", cam.proj_mat());
    try self.shader.set_uint("u_instance_cnt", @intCast(self.instances.items.len));

    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(NODE_TREE),
        self.nodes_ssbo,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(INSTANCE_DATA),
        self.instance_ssbo,
    ));

    for (self.primitives) |*p| {
        try p.draw(self.instances.items.len);
    }
}

pub const InstanceId = enum(u32) { invalid = 0, _ };
pub fn add_instance(self: *glTF) !InstanceId {
    const idx = self.free_instances.pop() orelse blk: {
        const idx = self.instances.items.len;
        try self.instances.append(self.arena.allocator(), .{});
        break :blk idx;
    };
    self.instances.items[idx] = .{};
    self.updated = true;

    if (self.instance_ssbo_capacity == 0) {
        const initial_capacity = 10;
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.instance_ssbo));
        try gl_call(gl.BufferData(
            gl.SHADER_STORAGE_BUFFER,
            @intCast(initial_capacity * @sizeOf(InstanceData)),
            null,
            gl.DYNAMIC_DRAW,
        ));
        self.instance_ssbo_capacity = initial_capacity;
    }

    if (self.instances.items.len >= self.instance_ssbo_capacity) {
        const new_cap = self.instance_ssbo_capacity * 2;
        var new_buf: gl.uint = 0;
        try gl_call(gl.GenBuffers(1, @ptrCast(&new_buf)));
        try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, new_buf));
        try gl_call(gl.BufferData(
            gl.SHADER_STORAGE_BUFFER,
            @intCast(new_cap * @sizeOf(InstanceData)),
            null,
            gl.DYNAMIC_DRAW,
        ));
        try gl_call(gl.DeleteBuffers(1, @ptrCast(&self.instance_ssbo)));
        self.instance_ssbo = new_buf;
        self.instance_ssbo_capacity = new_cap;
    }

    return @enumFromInt(idx + 1);
}

pub fn remove_instance(self: *glTF, id: InstanceId) void {
    logger.warn("remove_instance doesnt actually do anything right now", .{});

    if (id == .invalid) {
        logger.warn("{*}: attempted to remove invalid instance id!", .{self});
        return;
    }
    self.free_instances.append(self.arena.allocator(), @intFromEnum(id) - 1) catch |err| {
        logger.warn("{*}: leaking instance {}: {}", .{ self, id, err });
    };
}

pub fn set_transform(self: *glTF, id: InstanceId, mat: zm.Mat4f) void {
    if (id == .invalid) {
        logger.warn("{*}: attempted to set transform on invalid instance id!", .{self});
        return;
    }
    self.updated = true;
    const idx: usize = @intFromEnum(id) - 1;
    self.instances.items[idx].transform = mat.transpose().data;
}

const InstanceData = packed struct {
    transform: @Vector(16, f32) = zm.Mat4f.identity().data,
};

fn upload(self: *glTF, parser: *Parser) !void {
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.instance_ssbo)));

    const gpa = self.arena.allocator();
    self.buffers = try gpa.alloc(gl.uint, parser.buffers.items.len);
    try gl_call(gl.GenBuffers(@intCast(parser.buffers.items.len), @ptrCast(self.buffers)));

    for (parser.buffers.items, self.buffers) |data, buf| {
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, buf));
        try gl_call(gl.BufferData(
            gl.ARRAY_BUFFER,
            @intCast(data.len),
            @ptrCast(data),
            gl.STATIC_DRAW,
        ));
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    }

    const meshes = parser.root.meshes orelse &.{};
    const mesh_parents = try parser.arena.allocator().alloc(std.ArrayList(u32), meshes.len);
    const nodes = parser.root.nodes orelse &.{};
    const node_data = try parser.arena.allocator().alloc(NodeData, nodes.len);
    for (node_data, nodes, 0..) |*data, n, idx| {
        const matrix = (zm.Mat4f{ .data = n.matrix }).transpose();
        const T = zm.Mat4f.translationVec3(n.translation);
        const R = zm.Mat4f.fromQuaternion(
            .init(n.rotation[3], n.rotation[0], n.rotation[1], n.rotation[2]),
        );
        const S = zm.Mat4f.scalingVec3(n.scale);
        const transform = matrix.multiply(T.multiply(R.multiply(S))).transpose();

        data.* = .{ .transform = transform.data, .parent = @intCast(idx) };
    }

    @memset(mesh_parents, .empty);
    for (parser.root.scenes orelse &.{}, 0..) |_, i| {
        try scene_dfs(
            &parser.root,
            i,
            save_parents,
            .{ mesh_parents, node_data, parser.arena.allocator(), &parser.root },
        );
    }

    var all_parents = std.ArrayList(u32).empty;
    for (mesh_parents) |mp| try all_parents.appendSlice(parser.arena.allocator(), mp.items);

    try gl_call(gl.GenBuffers(1, @ptrCast(&self.mesh_parents_vbo)));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.mesh_parents_vbo));
    try gl_call(gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(all_parents.items.len * @sizeOf(u32)),
        @ptrCast(all_parents.items),
        gl.STATIC_DRAW,
    ));

    try gl_call(gl.GenBuffers(1, @ptrCast(&self.nodes_ssbo)));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, self.nodes_ssbo));
    try gl_call(gl.BufferData(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(node_data.len * @sizeOf(NodeData)),
        @ptrCast(node_data),
        gl.STATIC_DRAW,
    ));
    try gl_call(gl.BindBufferBase(
        gl.SHADER_STORAGE_BUFFER,
        @intCast(NODE_TREE),
        self.nodes_ssbo,
    ));
    try gl_call(gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, 0));

    var prims = std.ArrayList(PrimitiveMesh).empty;
    defer prims.deinit(gpa);

    var parent_offset: usize = 0;
    for (mesh_parents, 0..) |parents, i| {
        const mesh = meshes[i];
        for (mesh.primitives) |prim| {
            const primitive = try PrimitiveMesh.init(
                self,
                &parser.root,
                prim,
                @intCast(parent_offset * @sizeOf(u32)),
                parents.items.len,
            );
            try prims.append(gpa, primitive);
        }
        parent_offset += parents.items.len;
    }

    self.primitives = try prims.toOwnedSlice(gpa);
}

const NodeData = packed struct(u640) {
    parent: u32 = 0,
    _padding: u96 = 0xdeaddeaddead,
    transform: @Vector(16, f32) = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
};

fn save_parents(
    mp: []std.ArrayList(u32),
    node_data: []NodeData,
    alloc: std.mem.Allocator,
    root: *Root,
    node: u32,
) !void {
    const n = &root.nodes.?[node];
    if (n.mesh) |m| try mp[m].append(alloc, node);
    if (n.children) |nodes| {
        for (nodes) |child| node_data[child].parent = node;
    }
}

fn scene_dfs(root: *Root, scene: usize, comptime fptr: anytype, args: anytype) !void {
    const s = &root.scenes.?[scene];
    if (s.nodes) |nodes| for (nodes) |node| {
        try node_dfs(root, node, fptr, args);
    };
}

fn node_dfs(root: *Root, node: u32, comptime fptr: anytype, args: anytype) !void {
    try @call(.auto, fptr, args ++ .{node});
    if (root.nodes.?[node].children) |nodes| for (nodes) |child| {
        try node_dfs(root, child, fptr, args);
    };
}

const Parser = struct {
    arena: std.heap.ArenaAllocator,
    root: Root,
    buffers: std.ArrayList([]const u8),

    fn init(gpa: std.mem.Allocator, file: *VFS.File) !Parser {
        logger.info("parsing .glb file: {s}", .{file.path});
        errdefer |err| {
            logger.err("{s}: parsing failed! {}", .{ file.path, err });
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const source = try file.read_all(arena.allocator());
        const src = source.src;

        var reader = std.Io.Reader.fixed(src);
        const magic = try reader.takeInt(u32, .little);
        if (magic != std.mem.bytesToValue(u32, "glTF")) return error.Magic;
        const version = try reader.takeInt(u32, .little);
        if (version != 2) return error.Version;
        const total_length = try reader.takeInt(u32, .little);
        std.debug.assert(source.src.len == total_length);

        var self = Parser{ .arena = arena, .root = undefined, .buffers = .empty };
        var cur_chunk: usize = 0;
        while (reader.seek != total_length) : (cur_chunk += 1) {
            errdefer |err| {
                logger.err(
                    "{s}: {}, while parsing chunk {d}, file offset {d}",
                    .{ source.path, err, cur_chunk, reader.seek },
                );
            }

            const length = try reader.takeInt(u32, .little);
            const typ = try reader.takeInt(u32, .little);
            if (src.len < reader.seek + length) return error.EndOfStream;

            switch (typ) {
                std.mem.bytesToValue(u32, "JSON") => {
                    const json = src[reader.seek .. reader.seek + length];
                    try reader.discardAll(length);

                    var json_reader = std.json.Scanner.initCompleteInput(
                        self.arena.allocator(),
                        json,
                    );
                    var diag = std.json.Diagnostics{};

                    errdefer |err| {
                        const ctx_len = 20;
                        const x = diag.getByteOffset();
                        const a = std.math.sub(u64, x, ctx_len) catch 0;
                        const b = @min(json.len, x + ctx_len);
                        const ctx = json[a..b];
                        var buf = std.mem.zeroes([ctx_len * 10]u8);
                        var w = std.Io.Writer.fixed(&buf);
                        var i = w.splatByte(' ', x - a) catch unreachable;
                        w.printAsciiChar('^', .{}) catch unreachable;
                        i += 1;

                        logger.err("{s}:{d}:{d} {}\n{s}\n{s}", .{
                            file.path,
                            diag.getLine(),
                            diag.getColumn(),
                            err,
                            ctx,
                            buf[0..i],
                        });
                    }
                    json_reader.enableDiagnostics(&diag);

                    self.root = try std.json.parseFromTokenSourceLeaky(
                        Root,
                        self.arena.allocator(),
                        &json_reader,
                        .{},
                    );
                },
                std.mem.bytesToValue(u32, &[4]u8{ 'B', 'I', 'N', 0 }) => {
                    try self.buffers.append(
                        self.arena.allocator(),
                        try reader.readAlloc(self.arena.allocator(), length),
                    );
                },
                else => {
                    logger.err(
                        "invalid chunk header 0x{X:08} ({s})",
                        .{ typ, std.mem.asBytes(&typ) },
                    );
                    return error.ChunkHeader;
                },
            }
        }
        logger.info("{s}: parsing ok!", .{file.path});
        return self;
    }
};

const PrimitiveMesh = struct {
    // TODO: sparse accessors
    vao: gl.uint,

    // TODO: right now we do not allow models without indices
    index_type: gl.@"enum",
    index_start: gl.uint,

    mode: gl.@"enum",
    count: usize, // index count
    per_model_instance_count: usize,

    fn init(
        model: *glTF,
        root: *Root,
        prim: Mesh.Primitive,
        parent_node_byte_offset: u32,
        parent_node_cnt: usize,
    ) !PrimitiveMesh {
        var self: PrimitiveMesh = undefined;
        self.mode = @intFromEnum(prim.mode);
        self.per_model_instance_count = parent_node_cnt;

        try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
        try gl_call(gl.BindVertexArray(self.vao));

        if (prim.indices == null) {
            logger.err("models with no indicies are unsupported", .{});
            return error.Unsupported;
        }
        {
            // TODO: how does stride work for IBOs?
            const accessor = root.accessors.?[prim.indices.?];
            self.index_type = @intFromEnum(accessor.componentType);
            self.count = accessor.count;
            const view = root.bufferViews.?[accessor.bufferView];

            self.index_start = (accessor.byteOffset orelse 0) + view.byteOffset;
            const buf_object = model.buffers[view.buffer];
            try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, buf_object));
        }

        for (std.enums.values(Mesh.Primitive.AttribMap.Attribute)) |attrib| {
            const idx = prim.attributes.map.get(attrib) orelse continue;
            const accessor = root.accessors.?[idx];
            const view = root.bufferViews.?[accessor.bufferView];
            const buf = model.buffers[view.buffer];

            try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, buf));

            // TODO: matrices have a different stride
            const stride: usize = if (view.byteStride) |s|
                @as(usize, @intCast(s))
            else
                accessor.type.component_count() * accessor.componentType.byte_size();
            const offset = (accessor.byteOffset orelse 0) + view.byteOffset;
            const location = locations.get(attrib);

            try gl_call(gl.VertexAttribPointer(
                location,
                @intCast(accessor.type.component_count()),
                @intFromEnum(accessor.componentType),
                @intFromBool(accessor.normalized),
                @intCast(stride),
                @intCast(offset),
            ));
            try gl_call(gl.EnableVertexAttribArray(location));
        }

        {
            try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, model.mesh_parents_vbo));
            try gl_call(gl.VertexAttribIPointer(
                NODE,
                1,
                gl.UNSIGNED_INT,
                4,
                parent_node_byte_offset,
            ));
            try gl_call(gl.EnableVertexAttribArray(NODE));
            try gl_call(gl.VertexAttribDivisor(NODE, 1));
        }

        try gl_call(gl.BindVertexArray(0));

        return self;
    }

    fn draw(self: *PrimitiveMesh, model_instance_count: usize) !void {
        try gl_call(gl.BindVertexArray(self.vao));
        try gl_call(gl.VertexAttribDivisor(NODE, @intCast(model_instance_count)));

        try gl_call(gl.DrawElementsInstanced(
            self.mode,
            @intCast(self.count),
            self.index_type,
            self.index_start,
            @intCast(model_instance_count * self.per_model_instance_count),
        ));

        try gl_call(gl.BindVertexArray(0));
    }

    fn deinit(self: *PrimitiveMesh) void {
        gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
    }
};

const Number = f32;
const Integer = u32;

const Accessor = struct {
    bufferView: Integer,
    byteOffset: ?Integer = null,
    componentType: ComponentType,
    normalized: bool = false,
    count: Integer,
    type: Type,
    max: ?[]const Number = null,
    min: ?[]const Number = null,
    sparse: ?Sparse = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const ComponentType = enum(u32) {
        BYTE = 5120,
        UNSIGNED_BYTE = 5121,
        SHORT = 5122,
        UNSIGNED_SHORT = 5123,
        UNSIGNED_INT = 5125,
        FLOAT = 5126,

        fn byte_size(self: ComponentType) usize {
            return switch (self) {
                .BYTE, .UNSIGNED_BYTE => 1,
                .SHORT, .UNSIGNED_SHORT => 2,
                .FLOAT, .UNSIGNED_INT => 4,
            };
        }
    };

    const Sparse = struct {
        count: Integer,
        indices: Indices,
        values: Values,
        extensions: ?Extension = null,
        extra: ?Extra = null,

        const Indices = struct {
            bufferView: Integer,
            byteOffset: Integer = 0,
            componentType: IndexComponentType,
            extensions: ?Extension = null,
            extra: ?Extra = null,
        };

        const IndexComponentType = enum(u32) {
            UNSIGNED_BYTE = 5121,
            UNSIGNED_SHORT = 5123,
            UNSIGNED_INT = 5125,
        };

        const Values = struct {
            bufferView: Integer,
            byteOffset: Integer = 0,
            extensions: ?Extension = null,
            extra: ?Extra = null,
        };
    };

    const Type = enum {
        SCALAR,
        VEC2,
        VEC3,
        VEC4,
        MAT2,
        MAT3,
        MAT4,

        fn component_count(self: Type) usize {
            return switch (self) {
                .SCALAR => 1,
                .VEC2 => 2,
                .VEC3 => 3,
                .VEC4, .MAT2 => 4,
                .MAT3 => 9,
                .MAT4 => 16,
            };
        }
    };
};

const Animation = struct {
    channels: []const Channel,
    samplers: []const AniSampler,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const Channel = struct {
        sampler: Integer,
        target: Target,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };
    const AniSampler = struct {
        input: Integer,
        interpolation: Interpolation = .LINEAR,
        output: Integer,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };

    const Target = struct {
        node: Integer,
        path: Property,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };

    const Property = enum { weights, translation, rotation, scale };
    const Interpolation = enum { LINEAR, STEP, CUBICSPLINE };
};

const Asset = struct {
    copyright: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    version: []const u8,
    minVersion: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const Buffer = struct {
    uri: ?[]const u8 = null,
    byteLength: Integer,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const BufferView = struct {
    buffer: Integer,
    byteOffset: Integer = 0,
    byteLength: Integer,
    byteStride: ?Integer = null,
    target: ?Target = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const Target = enum(u32) {
        ARRAY_BUFFER = 34962,
        ELEMENT_ARRAY_BUFFER = 34963,
    };
};

const Camera = struct {
    orthographic: ?Orthographic = null,
    perspective: ?Perspective = null,
    type: Type,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const Orthographic = struct {
        xmag: Number,
        ymag: Number,
        zfar: Number,
        znear: Number,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };
    const Perspective = struct {
        aspectRatio: ?Number = null,
        yfov: Number,
        zfar: ?Number = null,
        znear: Number,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };
    const Type = enum { orthographic, perspective };
};

const Extension = std.json.Value;

const Extra = std.json.Value;

const Root = struct {
    extensionsUsed: ?[]const []const u8 = null,
    extensionsRequired: ?[]const []const u8 = null,
    accessors: ?[]const Accessor = null,
    animations: ?[]const Animation = null,
    asset: Asset,
    buffers: ?[]const Buffer = null,
    bufferViews: ?[]const BufferView = null,
    cameras: ?[]const Camera = null,
    images: ?[]const Image = null,
    materials: ?[]const Material = null,
    meshes: ?[]const Mesh = null,
    nodes: ?[]const Node = null,
    samplers: ?[]const Sampler = null,
    scene: ?Integer = null,
    scenes: ?[]const Scene = null,
    skins: ?[]const Skin = null,
    textures: ?[]const Texture = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const Image = struct {
    uri: ?[]const u8 = null,
    mimeType: ?MimeType = null,
    bufferView: ?Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const MimeType = enum {
        @"image/jpeg",
        @"image/png",
    };
};

const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
    normalTexture: ?NormalTexture = null,
    occlusionTexture: ?OcclusionTexture = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: @Vector(3, Number) = @splat(0),
    alphaMode: AlphaMode = .OPAQUE,
    alphaCutoff: Number = 0.5,
    doubleSided: bool = false,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const PbrMetallicRoughness = struct {
        baseColorFactor: @Vector(4, Number) = @splat(1),
        baseColorTexture: ?TextureInfo = null,
        metallicFactor: Number = 1.0,
        roughnessFactor: Number = 1.0,
        metallicRoughnessTexture: ?TextureInfo = null,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };

    const NormalTexture = struct {
        index: Integer,
        texCoord: Integer = 0,
        scale: Number = 1.0,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };

    const OcclusionTexture = struct {
        index: Integer,
        texCoord: Integer = 0,
        strength: Number = 1.0,
        extensions: ?Extension = null,
        extra: ?Extra = null,
    };

    const AlphaMode = enum { OPAQUE, MASK, BLEND };
};

const Mesh = struct {
    primitives: []const Primitive,
    weights: ?[]const Number = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const Primitive = struct {
        attributes: AttribMap,
        indices: ?Integer = null,
        material: ?Integer = null,
        mode: Mode = .TRIANGLES,
        targets: ?[]const AttribMap = null,
        extensions: ?Extension = null,
        extra: ?Extra = null,

        const AttribMap = struct {
            const Attribute = enum { POSITION, NORMAL, TEXCOORD_0 };

            map: std.EnumMap(Attribute, Integer),

            pub fn jsonParse(
                alloc: std.mem.Allocator,
                source: anytype,
                opts: std.json.ParseOptions,
            ) !AttribMap {
                const T = std.enums.EnumFieldStruct(Attribute, ?Integer, @as(?Integer, null));
                const efs = try std.json.innerParse(T, alloc, source, opts);
                return .{ .map = .init(efs) };
            }
        };
        const Mode = enum(Integer) {
            POINTS,
            LINES,
            LINE_LOOP,
            LINE_STRIP,
            TRIANGLES,
            TRIANGLE_STRIP,
            TRIANGLE_FAN,
        };
    };
};

const Node = struct {
    camera: ?Integer = null,
    children: ?[]const Integer = null,
    skin: ?Integer = null,
    matrix: @Vector(16, Number) = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    mesh: ?Integer = null,
    rotation: @Vector(4, Number) = .{ 0, 0, 0, 1 },
    scale: @Vector(3, Number) = .{ 1, 1, 1 },
    translation: @Vector(3, Number) = .{ 0, 0, 0 },
    weights: ?[]const Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const Sampler = struct {
    magFilter: ?Integer = null,
    minFilter: ?Integer = null,
    wrapS: Wrap = .REPEAT,
    wrapT: Wrap = .REPEAT,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,

    const MagFilter = enum(u32) {
        NEAREST = 9728,
        LINEAR = 9729,
    };
    const MinFilter = enum(u32) {
        NEAREST = 9728,
        LINEAR = 9729,
        NEAREST_MIPMAP_NEAREST = 9984,
        LINEAR_MIPMAP_NEAREST = 9985,
        NEAREST_MIPMAP_LINEAR = 9986,
        LINEAR_MIPMAP_LINEAR = 9987,
    };
    const Wrap = enum(u32) {
        CLAMP_TO_EDGE = 33071,
        MIRRORED_REPEAT = 33648,
        REPEAT = 10497,
    };
};

const Scene = struct {
    nodes: ?[]const Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const Skin = struct {
    inverseBindMatrices: ?Integer = null,
    skeleton: ?Integer = null,
    joints: []const Integer,
    name: []const u8,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const Texture = struct {
    sampler: ?Integer = null,
    source: ?Integer = null,
    name: ?[]const u8 = null,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const TextureInfo = struct {
    index: Integer,
    texCoord: Integer = 0,
    extensions: ?Extension = null,
    extra: ?Extra = null,
};

const locations = std.EnumArray(Mesh.Primitive.AttribMap.Attribute, u32).init(.{
    .POSITION = 0,
    .NORMAL = 1,
    .TEXCOORD_0 = 2,
});

const NODE = 3;
const INSTANCE = 4;
const NODE_TREE = 10;
const INSTANCE_DATA = 11;

const vert =
    \\#version 460 core
++ blk: {
    var str: []const u8 = "";

    for (std.enums.values(Mesh.Primitive.AttribMap.Attribute)) |attrib| {
        str = str ++ std.fmt.comptimePrint(
            "\n#define {s} {d}",
            .{ @tagName(attrib), locations.get(attrib) },
        );
    }

    break :blk str;
} ++
    std.fmt.comptimePrint("\n#define NODE {d}", .{NODE}) ++
    std.fmt.comptimePrint("\n#define INSTANCE {d}", .{INSTANCE}) ++
    std.fmt.comptimePrint("\n#define NODE_TREE {d}", .{NODE_TREE}) ++
    std.fmt.comptimePrint("\n#define INSTANCE_DATA {d}", .{INSTANCE_DATA}) ++
    \\
    \\layout (location = POSITION) in vec3 vert_pos;
    \\layout (location = NORMAL) in vec3 vert_norm;
    \\layout (location = TEXCOORD_0) in vec2 vert_uv;
    \\
    \\layout (location = NODE) in uint mesh_node; 
    \\
    \\out vec3 frag_pos;
    \\out vec3 frag_norm;
    \\out vec2 frag_uv;
    \\
    \\uniform mat4 u_view;
    \\uniform mat4 u_proj;
    \\uniform uint u_instance_cnt;
    \\
    \\struct Node {
    \\  uint parent;
    \\  mat4 transform;
    \\};
    \\
    \\layout (std430, binding = NODE_TREE) readonly buffer NodeTree {
    \\  Node nodes[];
    \\};
    \\
    \\struct InstanceData {
    \\  mat4 transform;
    \\};
    \\
    \\layout (std430, binding = INSTANCE_DATA) readonly buffer InstanceDataBuf {
    \\  InstanceData instance_data[];
    \\};
    \\
    \\mat4 compute_transform() {
    \\  mat4 model = mat4(1.0);
    \\  uint cur_node = mesh_node;
    \\  while (true) {
    \\    model = nodes[cur_node].transform * model;
    \\    if (cur_node == nodes[cur_node].parent) break;
    \\    cur_node = nodes[cur_node].parent;
    \\  }
    \\  return model;
    \\}
    \\
    \\void main() {
    \\  mat4 model = instance_data[gl_InstanceID % u_instance_cnt].transform * 
    \\    compute_transform();
    \\  mat4 norm_transform = model;
    \\  norm_transform[3] = vec4(0, 0, 0, 1);
    \\  norm_transform = inverse(transpose(norm_transform));
    \\
    \\  vec4 view_norm = u_view * norm_transform * vec4(vert_norm, 0);
    \\  vec4 view_pos = u_view * model * vec4(vert_pos, 1);
    \\  
    \\  frag_pos = view_pos.xyz;
    \\  frag_norm = view_norm.xyz;
    \\  frag_uv = vert_uv;
    \\  gl_Position = u_proj * view_pos;
    \\}
    \\
;

const frag =
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
    \\in vec3 frag_pos;
    \\in vec3 frag_norm;
    \\in vec2 frag_uv;
    \\
    \\void main() {
    \\  out_color = vec4(frag_uv, 1, 1);
    \\  out_pos = vec4(frag_pos, 1);
    \\  out_norm = vec4(frag_norm, 1);
    \\}
;
