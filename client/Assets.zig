const std = @import("std");

const Assets = @import("Assets.zig");
const logger = std.log.scoped(.assets);
const OOM = std.mem.Allocator.Error;

names: std.StringArrayHashMapUnmanaged([]const []const u8),
file_tree: PathTrie(void),
builtins: std.StaticStringMap([:0]const u8),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator, root_dir: []const u8) !Assets {
    var dir = try std.fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();
    var arena = std.heap.ArenaAllocator.init(gpa);

    var trie = try PathTrie(void).init(arena.allocator());
    inline for (builtin[1]) |path| {
        try trie.add(path, {});
    }
    try scan_dir(trie.visitor(), dir);

    var self = Assets{
        .arena = arena,
        .file_tree = trie,
        .builtins = .initComptime(builtin[0]),
        .names = .empty,
    };
    try trie.visitor().visit(on_visit, .{&self});

    return self;
}

pub fn deinit(self: *Assets) void {
    self.arena.deinit();
}

pub const FileTreeVisitor = PathTrie(void).Visitor;
pub fn visit_dir(self: *Assets, dir: []const u8, comptime fptr: anytype, args: anytype) !void {
    var visitor: FileTreeVisitor = self.file_tree.visitor();
    var it = try std.fs.path.componentIterator(dir);
    while (it.next()) |sub| visitor = visitor.step(sub.name) orelse return error.NoSuchPath;
    try visitor.visit(fptr, args);
}

pub fn get_src_by_name(self: *Assets, gpa: std.mem.Allocator, name: []const u8) !Source {
    if (self.builtins.get(name)) |src| return Source{ .name = name, .src = src, .src_needs_free = false };

    const path = self.names.get(name) orelse return error.MissingFile;

    var dir = try std.fs.cwd().openDir("assets", .{});
    defer dir.close();
    for (path[0 .. path.len - 1]) |s| {
        const next = try dir.openDir(s, .{});
        dir.close();
        dir = next;
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

    return Source{ .name = name, .src = src, .src_needs_free = true };
}

pub fn get_zon_by_name(self: *Assets, gpa: std.mem.Allocator, name: []const u8) !Zon {
    var src = try self.get_src_by_name(gpa, name);
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

fn get_name(gpa: std.mem.Allocator, paths: []const []const u8) ![:0]const u8 {
    std.debug.assert(paths.len > 0);
    const file_name = paths[paths.len - 1];
    const ext = std.fs.path.extension(file_name);
    const name = file_name[0 .. file_name.len - ext.len];

    var len: usize = 0;
    for (paths) |s| len += s.len;
    len -= ext.len;
    len += paths.len; // for dots

    const buf = try gpa.allocSentinel(u8, len, 0);
    var w = std.Io.Writer.fixed(buf);
    for (paths[0 .. paths.len - 1]) |s| try w.print(".{s}", .{s});
    try w.print(".{s}", .{name});

    return buf;
}

fn on_visit(self: *Assets, visitor: PathTrie(void).Visitor) !void {
    if (visitor.value() == null) return;
    const path = try visitor.trace(self.arena.allocator());
    const name = try get_name(self.arena.allocator(), path);
    if (try self.names.fetchPut(self.arena.allocator(), name, path)) |_| {
        logger.warn("duplicate asset with name '{s}'", .{name});
    }
    logger.info("found asset {s}", .{name});
}

fn scan_dir(trie: PathTrie(void).Visitor, parent: std.fs.Dir) !void {
    var it = parent.iterate();
    while (try it.next()) |entry| switch (entry.kind) {
        .directory => {
            var dir = try parent.openDir(entry.name, .{ .iterate = true });
            defer dir.close();
            try scan_dir(try trie.step_add(entry.name), dir);
        },
        .file => {
            const leaf = try trie.step_add(entry.name);
            leaf.set_value({});
        },
        else => continue,
    };
}

const builtin = blk: {
    const List = @import("Build").Assets;
    const names = @typeInfo(List).@"struct".decls;
    const KV = struct { [:0]const u8, [:0]const u8 };
    var kvs = std.mem.zeroes([names.len]KV);
    var paths = std.mem.zeroes([names.len][]const []const u8);

    for (names, 0..) |path, i| {
        const val: [:0]const u8 = @field(List, path.name);
        const ext = std.fs.path.extension(path.name);
        if (std.fs.path.componentIterator(path.name)) |iter| {
            var it = iter;
            var name: []const u8 = "";
            var arr: []const []const u8 = &.{};
            while (it.next()) |s| {
                arr = arr ++ .{s.name};
                name = &std.fmt.comptimePrint("{s}.{s}", .{ name, s.name }).*;
            }
            name = name[0 .. name.len - ext.len];
            paths[i] = arr;
            kvs[i] = .{ @ptrCast(name ++ .{0}), val };
        } else |err| {
            std.debug.panic("Error while creating iterator for {s}: {}", .{ path.name, err });
        }
    }

    break :blk .{ kvs, paths };
};

fn PathTrie(comptime T: type) type {
    return struct {
        const Node = struct {
            next: std.StringArrayHashMapUnmanaged(*Node) = .empty,
            value: ?T = null,
            parent: ?*Node = null,
            last_key: ?[]const u8 = null,
        };

        root: *Node,
        pool: std.heap.MemoryPool(Node),
        gpa: std.mem.Allocator,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) !Self {
            var self = Self{
                .pool = .init(gpa),
                .root = undefined,
                .gpa = gpa,
            };
            self.root = try self.new_node();
            return self;
        }

        pub fn add(self: *Self, path: []const []const u8, val: T) !void {
            var cur = self.visitor();
            for (path) |s| cur = try cur.step_add(s);
            cur.set_value(val);
        }

        pub fn get(self: *const Self, path: []const []const u8) ?T {
            var cur = self.visitor();
            for (path) |s| cur = cur.step(s) orelse return null;
            return cur.value();
        }

        pub fn visitor(self: *Self) Visitor {
            return Visitor{ .root = self.root, .trie = self };
        }

        fn new_node(self: *Self) !*Node {
            const node = try self.pool.create();
            node.* = Node{};
            return node;
        }

        pub const Visitor = struct {
            root: *Node,
            trie: *Self,

            pub fn step(self: Visitor, dir: []const u8) ?Visitor {
                const next = self.root.next.get(dir) orelse return null;
                return .{ .root = next, .trie = self.trie };
            }

            pub fn step_add(self: Visitor, dir: []const u8) !Visitor {
                const next = self.root.next.get(dir) orelse blk: {
                    const n: *Node = try self.trie.new_node();
                    try self.root.next.put(self.trie.gpa, dir, n);
                    n.parent = self.root;
                    n.last_key = try self.trie.gpa.dupeZ(u8, dir);
                    break :blk n;
                };
                return .{ .root = next, .trie = self.trie };
            }

            pub fn value(self: Visitor) ?*T {
                if (self.root.value) |*x| return x;
                return null;
            }

            pub fn set_value(self: Visitor, val: T) void {
                self.root.value = val;
            }

            pub fn trace(self: Visitor, gpa: std.mem.Allocator) ![]const []const u8 {
                var cnt: usize = 0;
                var cur = self.root;
                while (true) : (cnt += 1) {
                    cur = cur.parent orelse break;
                }
                if (cnt == 0) return &.{};

                const buf = try gpa.alloc([]const u8, cnt);
                var i: usize = cnt;
                cur = self.root;
                while (cur.parent) |next| {
                    i -= 1;
                    buf[i] = cur.last_key.?;
                    cur = next;
                }
                std.debug.assert(i == 0);
                return buf;
            }

            pub fn visit(self: Visitor, comptime fptr: anytype, args: anytype) !void {
                try @call(.auto, fptr, args ++ .{self});
                for (self.root.next.values()) |next| {
                    const sub = Visitor{ .root = next, .trie = self.trie };
                    try sub.visit(fptr, args);
                }
            }
        };
    };
}
