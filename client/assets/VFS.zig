const std = @import("std");

pool: std.heap.MemoryPool(Node),
root_node: *Dir,
root_dir: []const u8,
arena: std.heap.ArenaAllocator,

const VFS = @This();
const logger = std.log.scoped(.vfs);
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
) OOM!*VFS {
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
        const file = self.root().make_or_get_file(kv.path) catch |err| {
            logger.warn("could not register file {s}: {}", .{ kv.path, err });
            continue;
        };
        file.builtin = kv.source;
    }

    var dir = std.fs.cwd().openDir(root_dir, .{ .iterate = true }) catch |err| {
        logger.warn("could not open root dir {s}: {}", .{ root_dir, err });
        return self;
    };
    defer dir.close();
    var stack: std.array_list.Managed([]const u8) = .init(gpa);
    defer stack.deinit();

    scan_dir(self.root(), &stack, dir) catch |err| {
        logger.warn("could not scan root dir {s}: {}", .{ root_dir, err });
    };

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
        const alloc = self.vfs.arena.allocator();
        while (it.next()) |entry| {
            const name = entry.name;
            const next = cur.entries.get(name) orelse blk: {
                const node: *Node = try self.vfs.pool.create();
                node.* = .{ .dir = .{
                    .parent = cur,
                    .vfs = self.vfs,
                    .path = try std.fs.path.join(alloc, &.{ cur.path, name }),
                    .entries = .empty,
                } };
                try cur.entries.put(alloc, try alloc.dupe(u8, name), node);
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
        const cur = if (std.fs.path.dirname(sub_path)) |s|
            try self.make_or_get_dir(s)
        else
            self;

        const name = std.fs.path.basename(sub_path);
        const alloc = self.vfs.arena.allocator();
        const node = cur.entries.get(name) orelse blk: {
            const node: *Node = try self.vfs.pool.create();
            node.* = .{ .file = .{
                .parent = cur,
                .vfs = self.vfs,
                .path = try std.fs.path.join(alloc, &.{ cur.path, name }),
            } };
            try cur.entries.put(alloc, try alloc.dupe(u8, name), node);
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

    pub fn visit_no_fail(self: *Dir, comptime fptr: anytype, args: anytype) bool {
        for (self.entries.values()) |node| {
            switch (node.*) {
                .dir => |*dir| if (!dir.visit_no_fail(fptr, args)) return false,
                .file => |*file| {
                    @call(.auto, fptr, args ++ .{file}) catch |err| {
                        logger.err("{s}: could not visit: {}", .{ file.path, err });
                        return false;
                    };
                },
            }
        }
        return true;
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

    pub fn read_all(self: *File, alloc: std.mem.Allocator) !Source {
        if (self.builtin) |src| return .{ .src = src, .path = self.path, .src_static = true };

        var dir = try std.fs.cwd().openDir(self.vfs.root_dir, .{});
        defer dir.close();
        var file = try dir.openFile(self.path, .{});
        defer file.close();
        var buf = std.mem.zeroes([256]u8);
        var reader = file.reader(&buf);
        const size = try reader.getSize();
        const src = try alloc.allocSentinel(u8, size, 0);
        try reader.interface.readSliceAll(src);

        return .{ .src = src, .path = self.path };
    }

    fn print(
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

fn scan_dir(cur: *Dir, stack: *std.array_list.Managed([]const u8), dir: std.fs.Dir) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| switch (entry.kind) {
        .directory => {
            var fs_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer fs_dir.close();
            const vfs_dir = try cur.make_or_get_dir(entry.name);

            try stack.append(entry.name);
            defer _ = stack.pop();

            scan_dir(vfs_dir, stack, fs_dir) catch |err| {
                logger.warn(
                    "could not scan dir: {f}: {}",
                    .{ std.fs.path.fmtJoin(stack.items), err },
                );
            };
        },
        .file => {
            _ = cur.make_or_get_file(entry.name) catch |err| {
                logger.warn(
                    "could not register file {f}/{s}: {}",
                    .{ std.fs.path.fmtJoin(stack.items), entry.name, err },
                );
            };
        },
        else => continue,
    };
}

pub const Source = struct {
    path: []const u8,
    src: [:0]const u8,
    src_static: bool = false,

    pub fn deinit(self: Source, gpa: std.mem.Allocator) void {
        if (self.src_static) return;
        gpa.free(self.src);
    }

    pub fn parse_zon(self: Source, gpa: std.mem.Allocator) !Zon {
        return try Zon.from_src(self, gpa);
    }
};

pub const Zon = struct {
    src: Source,
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,

    pub fn from_src(src: Source, gpa: std.mem.Allocator) !Zon {
        const ast = try std.zig.Ast.parse(gpa, src.src, .zon);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        if (zoir.hasCompileErrors()) {
            logger.err("could not parse {s} as zon\n", .{src.path});
            var buf = std.mem.zeroes([256]u8);
            const stderr = std.debug.lockStderrWriter(&buf);
            defer std.debug.unlockStderrWriter();
            for (ast.errors) |err| {
                ast.renderError(err, stderr) catch unreachable;
                try stderr.print("\n", .{});
            }
            return error.ParseZon;
        }

        return Zon{ .ast = ast, .zoir = zoir, .src = src };
    }

    pub fn deinit(self: Zon, gpa: std.mem.Allocator) void {
        self.src.deinit(gpa);
        self.ast.deinit(gpa);
        self.zoir.deinit(gpa);
    }

    pub fn parse(self: Zon, comptime T: type, gpa: std.mem.Allocator) !T {
        var diag = std.zon.parse.Diagnostics{};
        errdefer |err| {
            logger.warn("{s}: {}\n{f}", .{ self.src.path, err, diag });
        }
        return try std.zon.parse.fromZoir(T, gpa, self.ast, self.zoir, &diag, .{});
    }

    pub fn parse_node(self: Zon, comptime T: type, gpa: std.mem.Allocator, node: std.zig.Zoir.Node.Index) !T {
        var diag = std.zon.parse.Diagnostics{};
        errdefer |err| {
            logger.warn("{s}: {}\n{f}", .{ self.src.path, err, diag });
        }
        return try std.zon.parse.fromZoirNode(
            T,
            gpa,
            self.ast,
            self.zoir,
            node,
            &diag,
            .{ .ignore_unknown_fields = true },
        );
    }
};
