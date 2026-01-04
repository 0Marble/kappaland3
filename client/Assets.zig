const std = @import("std");
const Options = @import("Build").Options;
const VFS = @import("assets/VFS.zig");

const Assets = @import("Assets.zig");
const logger = std.log.scoped(.assets);
const OOM = std.mem.Allocator.Error;

vfs: *VFS,
names: std.StringArrayHashMapUnmanaged(*VFS.File),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator) !Assets {
    var self = Assets{
        .vfs = try VFS.init(gpa, Options.assets_dir, &builtins),
        .names = .empty,
        .arena = .init(gpa),
    };
    try self.vfs.root().visit(register_asset, .{&self});
    std.log.debug("{f}", .{self.vfs.root()});

    return self;
}

pub fn deinit(self: *Assets) void {
    self.vfs.deinit();
    self.arena.deinit();
}

fn register_asset(self: *Assets, file: *VFS.File) !void {
    const name = try self.path_to_name(file.path);
    try self.names.put(self.arena.allocator(), name, file);
    logger.info("found asset: {s}", .{name});
}

fn path_to_name(self: *Assets, path: []const u8) ![:0]const u8 {
    var it = try std.fs.path.componentIterator(std.fs.path.dirname(path) orelse "");
    var buf = try std.ArrayList(u8).initCapacity(self.arena.allocator(), path.len);
    var writer = buf.writer(self.arena.allocator());
    while (it.next()) |s| try writer.print(".{s}", .{s.name});

    const file_name = std.fs.path.stem(path);
    try writer.print(".{s}", .{file_name});
    try buf.append(self.arena.allocator(), 0);

    return @ptrCast(buf.items);
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
