const std = @import("std");
const Options = @import("Build").Options;
const VFS = @import("assets/VFS.zig");
const TextureAtlas = @import("assets/TextureAtlas.zig");
const Models = @import("assets/Models.zig");
const Blocks = @import("assets/Blocks.zig");
const glTF = @import("assets/glTF.zig");

const Assets = @import("Assets.zig");
const logger = std.log.scoped(.assets);
const OOM = std.mem.Allocator.Error;

arena: std.heap.ArenaAllocator,

vfs: *VFS,
blocks_atlas: TextureAtlas,
models: Models,
blocks: Blocks,

pub fn init(gpa: std.mem.Allocator) !Assets {
    logger.info("loading assets...", .{});
    var vfs = try VFS.init(gpa, Options.assets_dir, &builtins);
    errdefer vfs.deinit();

    const blocks_atlas_dir = Options.textures_dir ++ "/blocks";
    var blocks_atlas = try TextureAtlas.init(gpa, try vfs.root().get_dir(blocks_atlas_dir));
    errdefer blocks_atlas.deinit();
    var models = try Models.init(gpa, try vfs.root().get_dir(Options.models_dir));
    errdefer models.deinit();

    var blocks = try Blocks.init(
        gpa,
        try vfs.root().get_dir(Options.blocks_dir),
        &blocks_atlas,
        &models,
    );
    errdefer blocks.deinit();

    const self = Assets{
        .vfs = vfs,
        .blocks_atlas = blocks_atlas,
        .models = models,
        .blocks = blocks,
        .arena = .init(gpa),
    };

    logger.info("loading assets complete!", .{});
    return self;
}

pub fn deinit(self: *Assets) void {
    self.vfs.deinit();
    self.blocks_atlas.deinit();
    self.models.deinit();
    self.arena.deinit();
    self.blocks.deinit();
}

pub fn to_name(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var it = try std.fs.path.componentIterator(std.fs.path.dirname(path) orelse "");

    var buf = std.ArrayList(u8).empty;
    try buf.ensureTotalCapacity(gpa, path.len);
    var w = buf.writer(gpa);
    while (it.next()) |s| try w.print(".{s}", .{s.name});
    try w.print(".{s}", .{std.fs.path.stem(path)});

    return buf.items;
}

pub fn get_vfs(self: *Assets) *VFS {
    return self.vfs;
}

pub fn get_blocks(self: *Assets) *Blocks {
    return &self.blocks;
}

pub fn get_blocks_atlas(self: *Assets) *TextureAtlas {
    return &self.blocks_atlas;
}

pub fn get_models(self: *Assets) *Models {
    return &self.models;
}

const builtins = blk: {
    const List = @import("Build").Assets;
    const names = @typeInfo(List).@"struct".decls;
    var kvs = std.mem.zeroes([names.len]VFS.PathSourcePair);

    for (names, 0..) |path, i| {
        kvs[i] = .{ .path = path.name, .source = @field(List, path.name) };
    }

    break :blk kvs;
};
