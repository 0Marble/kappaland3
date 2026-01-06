const std = @import("std");
const Options = @import("Build").Options;
const VFS = @import("assets/VFS.zig");
const TextureAtlas = @import("assets/TextureAtlas.zig");

const Assets = @import("Assets.zig");
const logger = std.log.scoped(.assets);
const OOM = std.mem.Allocator.Error;

vfs: *VFS,
arena: std.heap.ArenaAllocator,

blocks_atlas: TextureAtlas,

pub fn init(gpa: std.mem.Allocator) !Assets {
    var self = Assets{
        .vfs = try VFS.init(gpa, Options.assets_dir, &builtins),
        .arena = .init(gpa),
        .blocks_atlas = undefined,
    };
    self.blocks_atlas = try .init(gpa, try self.vfs.root().get_dir(Options.textures_dir ++ "/blocks"));

    return self;
}

pub fn deinit(self: *Assets) void {
    self.vfs.deinit();
    self.blocks_atlas.deinit();
    self.arena.deinit();
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

const builtins = blk: {
    const List = @import("Build").Assets;
    const names = @typeInfo(List).@"struct".decls;
    var kvs = std.mem.zeroes([names.len]VFS.PathSourcePair);

    for (names, 0..) |path, i| {
        kvs[i] = .{ .path = path.name, .source = @field(List, path.name) };
    }

    break :blk kvs;
};
