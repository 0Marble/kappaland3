const std = @import("std");
const App = @import("App.zig");
const TextureAtlas = @import("TextureAtlas.zig");
const Block = @import("Block.zig");
const Options = @import("ClientOptions");
const util = @import("util.zig");

const logger = std.log.scoped(.block_manager);

atlas: TextureAtlas,
blocks: std.StringArrayHashMapUnmanaged(Info),
models: std.StringArrayHashMapUnmanaged(Block.Model),
arena: std.heap.ArenaAllocator,

const BlockManager = @This();
const OOM = std.mem.Allocator.Error;

pub fn init() !BlockManager {
    logger.info("loading blocks", .{});
    const textures_path = try std.fs.path.join(
        App.frame_alloc(),
        &.{ "assets", Options.textures_dir, "blocks" },
    );
    logger.info("scanning block textures in {s}", .{textures_path});

    var self: BlockManager = .{
        .atlas = try .init(textures_path, "blocks"),
        .blocks = .empty,
        .models = .empty,
        .arena = .init(App.gpa()),
    };

    var scanner = Builder{ .arena = .init(App.gpa()) };
    defer scanner.deinit();

    const blocks_path = try std.fs.path.join(
        App.frame_alloc(),
        &.{ "assets", Options.blocks_dir },
    );
    logger.info("scanning blocks in {s}", .{blocks_path});
    scanner.scan(blocks_path, ParsedBlock.parse_and_store);
    logger.info("found {d} blocks", .{scanner.blocks.count()});

    const models_path = try std.fs.path.join(
        App.frame_alloc(),
        &.{ "assets", Options.models_dir, "blocks" },
    );
    logger.info("scanning block models in {s}", .{models_path});
    scanner.scan(models_path, ParsedModel.parse_and_store);
    logger.info("found {d} block models", .{scanner.models.count()});

    try scanner.register(&self);
    Block.cached_air = self.get_block_by_name(".blocks.main.air") orelse {
        logger.err("missing air block!", .{});
        return error.MissingAirBlock;
    };

    if (scanner.had_errors) {
        logger.warn("had errors while loading blocks...", .{});
    } else {
        logger.warn("loading blocks ok!", .{});
    }

    return self;
}

pub fn deinit(self: *BlockManager) void {
    self.atlas.deinit();
    self.blocks.deinit(App.gpa());
    self.models.deinit(App.gpa());
    self.arena.deinit();
}

pub fn get_block_by_name(self: *BlockManager, name: []const u8) ?Block {
    const b = self.blocks.getIndex(name) orelse return null;
    return .{ .idx = @intCast(b) };
}

fn concat(
    prefix: []const u8,
    strs: []const []const u8,
    suffix: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(App.gpa());
    const w = buf.writer(App.gpa());

    try w.print(".{s}", .{prefix});
    for (strs) |s| try w.print(".{s}", .{s});
    try w.print(".{s}", .{suffix});

    const gpa = App.static_alloc();
    const res = try gpa.dupeZ(u8, buf.items);
    return res;
}

fn concat_state(self: *BlockManager, base: []const u8, state: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(App.gpa());
    const w = buf.writer(App.gpa());

    try w.print("{s}", .{base});
    for (state) |s| try w.print(":{s}", .{s});

    const gpa = self.arena.allocator();
    const res = try gpa.dupeZ(u8, buf.items);
    return res;
}

const Builder = struct {
    had_errors: bool = false,

    prefix: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    blocks: std.StringArrayHashMapUnmanaged(*ParsedBlock) = .empty,
    realized: std.StringArrayHashMapUnmanaged(*ParsedBlock) = .empty,
    models: std.StringArrayHashMapUnmanaged(ParsedModel) = .empty,

    fn deinit(self: *Builder) void {
        self.prefix.deinit(App.gpa());
        self.blocks.deinit(App.gpa());
        self.models.deinit(App.gpa());
        self.realized.deinit(App.gpa());
        self.arena.deinit();
    }

    fn scan(self: *Builder, root: []const u8, comptime fptr: anytype) void {
        var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
            self.had_errors = true;
            logger.err("Could not open root dir {s}: {}", .{ root, err });
            return;
        };
        defer dir.close();
        self.scan_rec(dir, fptr) catch |err| {
            self.had_errors = true;
            logger.err("Could not scan root dir {s}: {}", .{ root, err });
        };
    }

    fn scan_rec(
        self: *Builder,
        parent: std.fs.Dir,
        comptime fptr: anytype,
    ) !void {
        var it = parent.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    try self.prefix.append(App.gpa(), entry.name);
                    defer _ = self.prefix.pop();

                    var dir = parent.openDir(entry.name, .{ .iterate = true }) catch |err| {
                        self.had_errors = true;
                        logger.err(
                            "error while opening dir {f}: {}",
                            .{ self.fmt_path(entry.name), err },
                        );
                        continue;
                    };
                    defer dir.close();

                    self.scan_rec(dir, fptr) catch |err| {
                        self.had_errors = true;
                        logger.err(
                            "error while scanning dir {f}: {}",
                            .{ self.fmt_path(entry.name), err },
                        );
                    };
                },
                .file => {
                    @call(.auto, fptr, .{
                        self,
                        parent,
                        self.prefix.items,
                        entry.name,
                    }) catch |err| {
                        self.had_errors = true;
                        logger.err(
                            "error while reading file {f}: {}",
                            .{ self.fmt_path(entry.name), err },
                        );
                    };
                },
                else => continue,
            }
        }
    }

    const PathFmt = struct {
        b: *Builder,
        name: []const u8,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{f}/{s}", .{ std.fs.path.fmtJoin(self.b.prefix.items), self.name });
        }
    };

    fn fmt_path(self: *Builder, name: []const u8) PathFmt {
        return PathFmt{ .b = self, .name = name };
    }

    fn register(self: *Builder, manager: *BlockManager) !void {
        logger.info("registering models...", .{});
        try self.register_models(manager);
        logger.info("registering blocks...", .{});
        try self.register_blocks(manager);
    }

    fn register_models(self: *Builder, manager: *BlockManager) !void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            const model = Block.Model{
                .u_scale = @intFromEnum(entry.value_ptr.*.size[0]),
                .v_scale = @intFromEnum(entry.value_ptr.*.size[1]),
                .u_offset = @intFromEnum(entry.value_ptr.*.offset[0]),
                .v_offset = @intFromEnum(entry.value_ptr.*.offset[1]),
                .w_offset = @intFromEnum(entry.value_ptr.*.offset[2]),
            };
            const name = try manager.arena.allocator().dupe(u8, entry.key_ptr.*);
            try manager.models.put(App.gpa(), name, model);
            logger.info("registered model {s}", .{name});
        }
    }

    fn register_blocks(self: *Builder, manager: *BlockManager) !void {
        for (self.blocks.keys(), 0..) |name, idx| {
            self.register_block(manager, idx) catch |err| {
                self.had_errors = true;
                logger.err("error while registering block {s}: {}", .{ name, err });
            };
        }
    }

    fn realize_block(self: *Builder, idx: usize) !*ParsedBlock {
        const name = self.blocks.keys()[idx];
        if (self.realized.get(name)) |x| return x;

        const parsed = self.blocks.values()[idx];
        const base: ?*ParsedBlock = if (parsed.derives) |base_name| blk: {
            const base_idx = self.blocks.getIndex(base_name) orelse {
                logger.warn("{s}: missing data for base block {s}", .{ name, base_name });
                self.had_errors = true;
                break :blk null;
            };
            break :blk try self.realize_block(base_idx);
        } else null;

        const realized = try parsed.realize(base, self.arena.allocator(), true);
        try self.realized.put(App.gpa(), name, realized);
        return realized;
    }

    fn register_block(self: *Builder, manager: *BlockManager, idx: usize) !void {
        const realized = try self.realize_block(idx);
        var state_stack = std.array_list.Managed([]const u8).init(App.gpa());
        defer state_stack.deinit();

        const name = self.blocks.keys()[idx];
        try self.register_block_and_states(manager, realized, name, &state_stack);
    }

    fn register_block_and_states(
        self: *Builder,
        manager: *BlockManager,
        realized: *ParsedBlock,
        base_name: []const u8,
        state_stack: *std.array_list.Managed([]const u8),
    ) !void {
        var info = Info{
            .casts_ao = realized.casts_ao.?,
            .solid = realized.solid,
            .textures = .init(.{}),
            .model = .init(.{}),
        };

        const full_name = try manager.concat_state(base_name, state_stack.items);
        {
            var it = realized.textures.iterator();
            while (it.next()) |kv| {
                const arr = try manager.arena.allocator().alloc(usize, kv.value.len);
                for (kv.value.*, arr) |tex_name, *x| {
                    x.* = manager.atlas.get_idx_or_warn(tex_name);
                }
                info.textures.put(kv.key, arr);
            }
        }

        {
            var it = realized.model.iterator();
            while (it.next()) |kv| {
                const arr = try manager.arena.allocator().alloc(usize, kv.value.len);
                for (kv.value.*, arr) |model_name, *x| {
                    x.* = manager.models.getIndex(model_name) orelse blk: {
                        logger.warn("{s}: missing model {s}", .{ full_name, model_name });
                        self.had_errors = true;
                        break :blk 0;
                    };
                }
                info.model.put(kv.key, arr);
            }
        }

        try manager.blocks.put(App.gpa(), full_name, info);
        logger.info("registered block {s}", .{full_name});

        {
            var it = realized.states.iterator();
            while (it.next()) |kv| {
                try state_stack.append(kv.key_ptr.*);
                defer _ = state_stack.pop();
                const sub = try kv.value_ptr.*.realize(realized, self.arena.allocator(), false);

                self.register_block_and_states(
                    manager,
                    sub,
                    base_name,
                    state_stack,
                ) catch |err| {
                    self.had_errors = true;
                    logger.err(
                        "error while registering state {s} of {s}: {}",
                        .{ kv.key_ptr.*, full_name, err },
                    );
                };
            }
        }
    }
};

const ParsedBlock = struct {
    derives: ?[]const u8 = null,
    casts_ao: ?bool = null,
    solid: std.EnumMap(Block.Face, bool) = .init(.{}),
    model: std.EnumMap(Block.Face, []const []const u8) = .init(.{}),
    textures: std.EnumMap(Block.Face, []const []const u8) = .init(.{}),
    states: States = .empty,

    const States = std.StringArrayHashMapUnmanaged(*ParsedBlock);

    fn realize(
        self: *ParsedBlock,
        base: ?*ParsedBlock,
        gpa: std.mem.Allocator,
        inherit_states: bool,
    ) !*ParsedBlock {
        var new = try gpa.create(ParsedBlock);
        new.* = .{};
        new.casts_ao = self.casts_ao orelse (if (base) |b| b.casts_ao else null) orelse {
            logger.err("missing field: .casts_ao", .{});
            return error.MissingEntry;
        };

        inline for (.{ "solid", "model", "textures" }) |f| {
            var it1 = @field(self, f).iterator();
            while (it1.next()) |kv| @field(new, f).put(kv.key, kv.value.*);
            if (base) |b| {
                var it2 = @field(b, f).iterator();
                while (it2.next()) |kv| if (!@field(new, f).contains(kv.key)) {
                    @field(new, f).put(kv.key, kv.value.*);
                };
            }
            const Map = @FieldType(ParsedBlock, f);

            for (std.enums.values(Map.Key)) |k| {
                if (!@field(new, f).contains(k)) {
                    logger.err("missing entry for {s}{}", .{ f, k });
                    if (base) |b| {
                        logger.info("note: base contains {s}{}: {}", .{ f, k, @field(b, f).contains(k) });
                    }
                    logger.info("note: self contains {s}{}: {}", .{ f, k, @field(self, f).contains(k) });

                    return error.MissingEntry;
                }
            }
        }

        var it1 = self.states.iterator();
        while (it1.next()) |kv| {
            try new.states.put(gpa, kv.key_ptr.*, kv.value_ptr.*);
        }
        if (util.cond_capture(inherit_states, base)) |b| {
            var it2 = b.states.iterator();
            while (it2.next()) |kv| if (!new.states.contains(kv.key_ptr.*)) {
                try new.states.put(gpa, kv.key_ptr.*, kv.value_ptr.*);
            };
        }

        return new;
    }

    const HalfParsed = struct {
        const NotParsed = std.zig.Zoir.Node.Index;
        derives: ?[]const u8 = null,
        casts_ao: ?bool = null,
        solid: ?NotParsed = null,
        model: ?NotParsed = null,
        textures: ?NotParsed = null,
        states: ?NotParsed = null,
    };

    fn parse_and_store(
        builder: *Builder,
        dir: std.fs.Dir,
        prefix: []const []const u8,
        file_name: []const u8,
    ) !void {
        const ext: []const u8 = ".zon";
        if (!std.mem.eql(u8, ext, std.fs.path.extension(file_name))) {
            return error.NotAZonFile;
        }
        const name = file_name[0 .. file_name.len - ext.len];

        var file = try dir.openFile(file_name, .{});
        defer file.close();

        const gpa = builder.arena.allocator();
        var buf = std.mem.zeroes([256]u8);
        var reader = file.reader(&buf);
        const size = try reader.getSize();
        const src = try gpa.allocSentinel(u8, size, 0);
        try reader.interface.readSliceAll(src);

        const ast = try std.zig.Ast.parse(gpa, src, .zon);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        const parse_diag = std.zon.parse.Diagnostics{ .ast = ast, .zoir = zoir };
        if (zoir.hasCompileErrors()) {
            logger.err("{f}", .{parse_diag});
            return error.ParseZon;
        }

        const parsed = try parse_zon(builder, ast, zoir, .root);
        const full_name = try concat("blocks", prefix, name);
        try builder.blocks.put(App.gpa(), full_name, parsed);
    }

    const Error = OOM || error{ ParseZon, NotAStruct, MissingEntry };
    fn parse_zon(
        builder: *Builder,
        ast: std.zig.Ast,
        zoir: std.zig.Zoir,
        node: std.zig.Zoir.Node.Index,
    ) Error!*ParsedBlock {
        const gpa = builder.arena.allocator();

        var diag = std.zon.parse.Diagnostics{};
        const half_parsed = std.zon.parse.fromZoirNode(
            HalfParsed,
            gpa,
            ast,
            zoir,
            node,
            &diag,
            .{ .free_on_error = false },
        ) catch |err| {
            logger.err("{f}", .{diag});
            return err;
        };

        const parsed = try gpa.create(ParsedBlock);
        parsed.* = .{ .derives = half_parsed.derives };

        parsed.casts_ao = half_parsed.casts_ao;
        if (half_parsed.states) |n| parsed.states = try parse_states(builder, ast, zoir, n);
        if (half_parsed.solid) |n| {
            const K = Block.Face;
            const V = bool;
            parsed.solid = try parse_enum_map_with_shorthand(builder, ast, zoir, n, K, V);
        }
        if (half_parsed.model) |n| {
            const K = Block.Face;
            const V = []const []const u8;
            parsed.model = try parse_enum_map_with_shorthand(builder, ast, zoir, n, K, V);
        }
        if (half_parsed.textures) |n| {
            const K = Block.Face;
            const V = []const []const u8;
            parsed.textures = try parse_enum_map_with_shorthand(builder, ast, zoir, n, K, V);
        }

        return parsed;
    }

    fn parse_enum_map_with_shorthand(
        builder: *Builder,
        ast: std.zig.Ast,
        zoir: std.zig.Zoir,
        node: std.zig.Zoir.Node.Index,
        comptime K: type,
        comptime V: type,
    ) !std.EnumMap(K, V) {
        const gpa = builder.arena.allocator();
        const Struct = std.enums.EnumFieldStruct(K, ?V, @as(?V, null));

        const opts = std.zon.parse.Options{ .free_on_error = false };
        var diag = std.zon.parse.Diagnostics{};
        const parsed = if (std.zon.parse.fromZoirNode(V, gpa, ast, zoir, node, null, opts)) |ok| blk: {
            var x: Struct = .{};
            inline for (comptime std.meta.fieldNames(Struct)) |f| {
                @field(x, f) = ok;
            }
            break :blk x;
        } else |_| if (std.zon.parse.fromZoirNode(Struct, gpa, ast, zoir, node, &diag, opts)) |ok| blk: {
            break :blk ok;
        } else |err| {
            logger.err("{f}", .{diag});
            return err;
        };

        const map = std.EnumMap(K, V).init(parsed);
        for (std.enums.values(K)) |k| {
            if (!map.contains(k)) {
                logger.err("missing entry for {}", .{k});
                return error.MissingEntry;
            }
        }

        return map;
    }

    fn parse_states(
        builder: *Builder,
        ast: std.zig.Ast,
        zoir: std.zig.Zoir,
        node: std.zig.Zoir.Node.Index,
    ) !States {
        const zon_node = node.get(zoir);
        switch (zon_node) {
            .struct_literal => {},
            else => return error.NotAStruct,
        }

        const gpa = builder.arena.allocator();
        var res = States.empty;
        for (zon_node.struct_literal.names, 0..) |name, i| {
            const child_node = zon_node.struct_literal.vals.at(@intCast(i));
            const child = try parse_zon(builder, ast, zoir, child_node);
            try res.put(gpa, name.get(zoir), child);
        }
        return res;
    }
};

const ParsedModel = struct {
    kind: Kind,
    size: struct { Size, Size },
    offset: struct { Offset, Offset, Offset },

    const Kind = enum { face_model };

    const Size = enum(u4) {
        @"1/16" = 0,
        @"2/16",
        @"3/16",
        @"4/16",
        @"5/16",
        @"6/16",
        @"7/16",
        @"8/16",
        @"9/16",
        @"10/16",
        @"11/16",
        @"12/16",
        @"13/16",
        @"14/16",
        @"15/16",
        @"16/16",
    };

    const Offset = enum(u4) {
        @"0/16" = 0,
        @"1/16",
        @"2/16",
        @"3/16",
        @"4/16",
        @"5/16",
        @"6/16",
        @"7/16",
        @"8/16",
        @"9/16",
        @"10/16",
        @"11/16",
        @"12/16",
        @"13/16",
        @"14/16",
        @"15/16",
    };

    fn parse_and_store(
        builder: *Builder,
        dir: std.fs.Dir,
        prefix: []const []const u8,
        file_name: []const u8,
    ) !void {
        const ext: []const u8 = ".zon";
        if (!std.mem.eql(u8, ext, std.fs.path.extension(file_name))) {
            return error.NotAZonFile;
        }
        const name = file_name[0 .. file_name.len - ext.len];

        var file = try dir.openFile(file_name, .{});
        defer file.close();

        var buf = std.mem.zeroes([256]u8);
        var reader = file.reader(&buf);
        const size = try reader.getSize();
        const src = try builder.arena.allocator().allocSentinel(u8, size, 0);
        try reader.interface.readSliceAll(src);

        var diag = std.zon.parse.Diagnostics{};
        const model = std.zon.parse.fromSlice(
            ParsedModel,
            builder.arena.allocator(),
            src,
            &diag,
            .{ .free_on_error = false },
        ) catch |err| {
            logger.err("{f}", .{diag});
            return err;
        };
        const full_name = try concat("blocks", prefix, name);
        try builder.models.put(App.gpa(), full_name, model);
    }
};

const Info = struct {
    casts_ao: bool,
    solid: std.EnumMap(Block.Face, bool) = .initFull(false),
    model: std.EnumMap(Block.Face, []const usize) = .initFull(&.{}),
    textures: std.EnumMap(Block.Face, []const usize) = .initFull(&.{}),
};

const StrArrFmt = struct {
    arr: []const []const u8,
    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("[", .{});
        for (self.arr) |s| try writer.print("`{s}', ", .{s});
        try writer.print("]", .{});
    }
};
