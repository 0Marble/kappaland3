const std = @import("std");
const zm = @import("zm");
const gl = @import("gl");
const VFS = @import("VFS.zig");

const glTF = @This();
const logger = std.log.scoped(.gltf);

arena: std.heap.ArenaAllocator,
root: Root,
buffers: std.ArrayList([]const u8),

pub fn init(gpa: std.mem.Allocator, file: *VFS.File) !glTF {
    logger.info("parsing .glb file: {s}", .{file.path});
    errdefer |err| {
        logger.err("{s}: parsing failed! {}", .{ file.path, err });
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const source = try file.read_all(gpa);
    defer source.deinit(gpa);
    const src = source.src;

    var reader = std.Io.Reader.fixed(src);
    const magic = try reader.takeInt(u32, .little);
    if (magic != std.mem.bytesToValue(u32, "glTF")) return error.Magic;
    const version = try reader.takeInt(u32, .little);
    if (version != 2) return error.Version;
    const total_length = try reader.takeInt(u32, .little);
    std.debug.assert(source.src.len == total_length);

    var self = glTF{ .arena = arena, .root = undefined, .buffers = .empty };

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
                var temp = std.heap.stackFallback(256, arena.allocator());

                var json_reader = std.json.Scanner.initCompleteInput(temp.get(), json);
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

                    logger.err(
                        "{s}:{d}:{d} {}\n{s}\n{s}",
                        .{ file.path, diag.getLine(), diag.getColumn(), err, ctx, buf[0..i] },
                    );
                }
                json_reader.enableDiagnostics(&diag);

                self.root = try std.json.parseFromTokenSourceLeaky(
                    Root,
                    arena.allocator(),
                    &json_reader,
                    .{},
                );
            },
            std.mem.bytesToValue(u32, &[4]u8{ 'B', 'I', 'N', 0 }) => {
                try self.buffers.append(
                    arena.allocator(),
                    try reader.readAlloc(arena.allocator(), length),
                );
            },
            else => {
                logger.err("invalid chunk header 0x{X:08} ({s})", .{ typ, std.mem.asBytes(&typ) });
                return error.ChunkHeader;
            },
        }
    }

    logger.info("{s}: parsing ok!", .{file.path});
    return self;
}

pub fn deinit(self: *glTF) void {
    self.arena.deinit();
}

const Number = f64;
const Integer = u64;

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

    const Type = enum { SCALAR, VEC2, VEC3, VEC4, MAT2, MAT3, MAT4 };
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
    mineType: ?MimeType = null,
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
    emmisiveTexture: ?TextureInfo = null,
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
            map: std.StaticStringMap(Integer),

            pub fn jsonParse(
                alloc: std.mem.Allocator,
                source: anytype,
                opts: std.json.ParseOptions,
            ) !AttribMap {
                const obj: std.json.Value = try std.json.Value.jsonParse(alloc, source, opts);
                const map = switch (obj) {
                    .object => |map| map,
                    else => return error.UnknownField,
                };
                const kvs = try alloc.alloc(struct { []const u8, Integer }, map.count());
                for (map.keys(), map.values(), kvs) |name, val, *out| {
                    out.* = .{ name, try std.json.parseFromValueLeaky(Integer, alloc, val, .{}) };
                }

                return .{ .map = try .init(kvs, alloc) };
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
