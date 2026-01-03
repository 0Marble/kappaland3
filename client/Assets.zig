const std = @import("std");

const Assets = @import("Assets.zig");
const logger = std.log.scoped(.assets);
const OOM = std.mem.Allocator.Error;

paths: std.StaticStringMap([]const []const u8),
builtins: std.StaticStringMap([:0]const u8),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator, root_dir: []const u8) !Assets {
    var dir = try std.fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();
    var temp = std.heap.ArenaAllocator.init(gpa);
    defer temp.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);

    var scanner = Scanner{ .temp_gpa = temp.allocator(), .result_gpa = arena.allocator() };
    try scanner.scan(dir);

    return Assets{
        .arena = arena,
        .paths = try .init(scanner.kvs.items, arena.allocator()),
        .builtins = .initComptime(builtin_kvs),
    };
}

pub fn deinit(self: *Assets) !void {
    self.arena.deinit();
}

pub fn get_src(self: *Assets, gpa: std.mem.Allocator, name: []const u8) !Source {
    if (self.builtins.get(name)) |src| {
        return Source{ .name = name, .src = src, .src_needs_free = false };
    }

    const path = self.paths.get(name) orelse {
        return error.MissingAsset;
    };
    std.debug.assert(path.len > 0);

    var dir = std.fs.cwd();
    defer dir.close();
    for (path[0 .. path.len - 1]) |sub| {
        const next_dir = try dir.openDir(sub, .{});
        dir.close();
        dir = next_dir;
    }

    const file_name = path[path.len - 1];
    var file = try dir.openFile(file_name, .{});
    defer file.close();
    var buf = std.mem.zeroes([256]u8);
    var reader = file.reader(&buf);
    const size = try reader.getSize();
    const src = try gpa.allocSentinel(u8, size, 0);
    errdefer gpa.free(src);
    try reader.interface.readSliceAll(src);

    return Source{
        .name = name,
        .src = src,
        .src_needs_free = true,
    };
}

pub fn get_zon(self: *Assets, gpa: std.mem.Allocator, name: []const u8) !Zon {
    var src = try self.get_src(gpa, name);
    errdefer src.deinit(gpa);
    var diag = std.zon.parse.Diagnostics{};
    errdefer diag.deinit(gpa);

    _ = std.zon.parse.fromSlice(std.zig.Zoir.Node.Index, gpa, src.src, &diag, .{}) catch |err| {
        logger.err("could not parse {s}: {}\n{f}", .{ name, err, diag });
        return err;
    };
    return .{
        .name = name,
        .zoir = diag.zoir,
        .ast = diag.ast,
        .src_needs_free = src.src_needs_free,
    };
}

pub const Source = struct {
    name: []const u8,
    src: [:0]const u8,
    src_needs_free: bool = true,

    pub fn deinit(self: *Source, gpa: std.mem.Allocator) void {
        if (self.src_needs_free) gpa.free(self.src);
    }
};

pub const Zon = struct {
    name: []const u8,
    zoir: std.zig.Zoir,
    ast: std.zig.Ast,
    src_needs_free: bool,

    pub fn deinit(self: *Zon, gpa: std.mem.Allocator) void {
        if (self.src_needs_free) gpa.free(self.ast.source);
        self.ast.deinit(gpa);
        self.zoir.deinit(gpa);
    }

    pub fn parse(self: *Zon, comptime T: type, gpa: std.mem.Allocator) !T {
        var diag = std.zon.parse.Diagnostics{ .ast = self.ast, .zoir = self.zoir };
        const res = std.zon.parse.fromZoir(T, gpa, self.ast, self.zoir, &diag, .{}) catch |err| {
            logger.err("could not parse {s} as {s}: {}\n{f}", .{ self.name, @typeName(T), err, diag });
            return err;
        };
        return res;
    }
};

const Scanner = struct {
    prefix: std.ArrayList([]const u8) = .empty,
    kvs: std.ArrayList(struct { [:0]const u8, []const []const u8 }) = .empty,
    temp_gpa: std.mem.Allocator,
    result_gpa: std.mem.Allocator,

    fn get_name(self: *Scanner, name: []const u8) ![:0]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.temp_gpa);
        var w = buf.writer(self.temp_gpa);

        for (self.prefix.items) |s| try w.print(".{s}", .{s});
        try w.print(".{s}", .{name});

        return self.result_gpa.dupeZ(u8, buf.items);
    }

    fn get_path(self: *Scanner, file_name: []const u8) OOM![]const []const u8 {
        const new_arr = try self.result_gpa.alloc([]const u8, self.prefix.items.len + 1);
        for (self.prefix.items, 0..) |s, i| new_arr[i] = try self.result_gpa.dupe(u8, s);
        new_arr[new_arr.len - 1] = try self.result_gpa.dupe(u8, file_name);
        return new_arr;
    }

    fn scan(self: *Scanner, parent: std.fs.Dir) !void {
        var it = parent.iterate();
        while (try it.next()) |entry| switch (entry.kind) {
            .directory => {
                var dir = try parent.openDir(entry.name, .{ .iterate = true });
                defer dir.close();
                try self.prefix.append(self.temp_gpa, entry.name);
                defer _ = self.prefix.pop();
                try self.scan(dir);
            },
            .file => {
                const ext = std.fs.path.extension(entry.name);
                const name = entry.name[0 .. entry.name.len - ext.len];
                try self.kvs.append(self.temp_gpa, .{
                    try self.get_name(name),
                    try self.get_path(entry.name),
                });
            },
            else => continue,
        };
    }
};

const builtin_kvs = blk: {
    const KVs = @import("Build").Assets;
    const decl_names = @typeInfo(KVs).@"struct".decls;
    const KV = struct { [:0]const u8, [:0]const u8 };
    var kvs = std.mem.zeroes([decl_names.len]KV);

    for (decl_names, 0..) |name, i| {
        const val: [:0]const u8 = @field(KVs, name.name);
        kvs[i] = .{ name.name, val };
    }

    break :blk kvs;
};
