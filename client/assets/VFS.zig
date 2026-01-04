const std = @import("std");

pool: std.heap.MemoryPool(Node),
root_node: *Dir,
root_dir: []const u8,
arena: std.heap.ArenaAllocator,

const VFS = @This();
const ComponentIterError = @typeInfo(@typeInfo(@TypeOf(std.fs.path.componentIterator)).@"fn".return_type.?).error_union.error_set;
const OOM = std.mem.Allocator.Error;

pub const Error = error{
    NotFound,
    NotDir,
    NotFile,
    InvalidName,
    Exists,
} || ComponentIterError;

pub const PathSourcePair = struct {
    path: []const u8,
    source: [:0]const u8,
};
pub fn init(
    gpa: std.mem.Allocator,
    root_dir: []const u8,
    builtins: []const PathSourcePair,
) !*VFS {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var pool = std.heap.MemoryPool(Node).init(gpa);
    errdefer pool.deinit();

    const self = try arena.allocator().create(VFS);
    var root_node: *Node = try pool.create();
    root_node.* = .{ .dir = .{
        .vfs = self,
        .path = "",
        .entries = .empty,
        .parent = null,
    } };

    self.* = .{
        .arena = arena,
        .pool = pool,
        .root_node = &root_node.dir,
        .root_dir = root_dir,
    };

    for (builtins) |kv| {
        const file = try self.root().make_or_get_file(kv.path);
        file.builtin = kv.source;
    }

    var dir = try std.fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();
    try scan_dir(self.root(), dir);

    return self;
}

pub fn deinit(self: *VFS) void {
    self.pool.deinit();
    var arena = self.arena;
    arena.deinit();
}

pub fn root(self: *VFS) *Dir {
    return self.root_node;
}

pub const Dir = struct {
    path: []const u8,
    parent: ?*Dir,
    vfs: *VFS,
    entries: std.StringArrayHashMapUnmanaged(*Node),

    pub fn get_dir(self: *Dir, sub_path: []const u8) Error!*Dir {
        var it = try std.fs.path.componentIterator(sub_path);
        var cur = self;
        while (it.next()) |step| {
            const next = cur.entries.get(step.name) orelse return error.NotFound;
            switch (next.*) {
                .dir => |*x| cur = x,
                else => return error.NotDir,
            }
        }
        return cur;
    }

    pub fn get_file(self: *Dir, sub_path: []const u8) !*File {
        const dir = if (std.fs.path.dirname(sub_path)) |path|
            try self.get_dir(path)
        else
            self;
        const file_name = std.fs.path.stem(sub_path);
        const node = dir.entries.get(file_name) orelse return error.NotFound;
        switch (node.*) {
            .file => |*x| return x,
            else => return error.NotFile,
        }
    }

    pub fn make_or_get_dir(self: *Dir, sub_path: []const u8) (Error || OOM)!*Dir {
        var it = try std.fs.path.componentIterator(sub_path);
        var cur = self;
        while (it.next()) |entry| {
            const name = entry.name;
            const next = cur.entries.get(name) orelse blk: {
                const node: *Node = try self.vfs.pool.create();
                node.* = .{ .dir = .{
                    .parent = cur,
                    .vfs = self.vfs,
                    .path = try std.fs.path.join(self.vfs.arena.allocator(), &.{ cur.path, name }),
                    .entries = .empty,
                } };
                try cur.entries.put(self.vfs.arena.allocator(), name, node);
                break :blk node;
            };
            switch (next.*) {
                .dir => |*x| cur = x,
                else => return error.NotDir,
            }
        }
        return cur;
    }

    pub fn make_or_get_file(self: *Dir, sub_path: []const u8) !*File {
        const dir = if (std.fs.path.dirname(sub_path)) |s|
            try self.make_or_get_dir(s)
        else
            self;

        const file_name = std.fs.path.basename(sub_path);
        const node = dir.entries.get(file_name) orelse blk: {
            const node: *Node = try self.vfs.pool.create();
            node.* = .{ .file = .{
                .parent = dir,
                .vfs = self.vfs,
                .path = try std.fs.path.join(self.vfs.arena.allocator(), &.{ dir.path, file_name }),
            } };
            try dir.entries.put(self.vfs.arena.allocator(), file_name, node);
            break :blk node;
        };

        switch (node.*) {
            .file => |*file| return file,
            else => return error.NotFile,
        }
    }

    pub fn visit(self: *Dir, comptime fptr: anytype, args: anytype) !void {
        for (self.entries.values()) |node| {
            switch (node.*) {
                .dir => |*dir| try dir.visit(fptr, args),
                .file => |*file| try @call(.auto, fptr, args ++ .{file}),
            }
        }
    }

    pub fn format(
        self: *Dir,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try self.visit(File.print, .{writer});
    }
};

pub const File = struct {
    path: []const u8,
    parent: *Dir,
    vfs: *VFS,
    builtin: ?[:0]const u8 = null,

    pub fn read_all(self: *File, alloc: std.mem.Allocator) ![:0]const u8 {
        if (self.builtin) |src| return try alloc.dupeZ(u8, src);

        var dir = try std.fs.cwd().openDir(self.vfs.root_dir, .{});
        defer dir.close();
        var file = try dir.openFile(self.path, .{});
        defer file.close();
        var buf = std.mem.zeroes([256]u8);
        var reader = file.reader(&buf);
        const size = try reader.getSize();
        const src = try alloc.allocSentinel(u8, size, 0);
        try reader.interface.readSliceAll(src);

        return src;
    }

    pub fn print(
        writer: *std.Io.Writer,
        self: *File,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.path});
        if (self.builtin != null) try writer.print(" (builtin)", .{});
        try writer.print("\n", .{});
    }
};

const Node = union(enum) {
    dir: Dir,
    file: File,
};

fn scan_dir(cur: *Dir, dir: std.fs.Dir) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| switch (entry.kind) {
        .directory => {
            var fs_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer fs_dir.close();
            const vfs_dir = try cur.make_or_get_dir(entry.name);
            try scan_dir(vfs_dir, fs_dir);
        },
        .file => {
            _ = try cur.make_or_get_file(entry.name);
        },
        else => continue,
    };
}
