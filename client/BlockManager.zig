const std = @import("std");
const App = @import("App.zig");
const TextureAtlas = @import("TextureAtlas.zig");
const Block = @import("Block.zig");
const Options = @import("ClientOptions");
const util = @import("util.zig");

const logger = std.log.scoped(.block_manager);

atlas: TextureAtlas,
blocks: std.StringArrayHashMapUnmanaged(Info),
models: std.StringArrayHashMapUnmanaged(usize),
models_dedup: std.AutoArrayHashMapUnmanaged(Block.Model, void),
arena: std.heap.ArenaAllocator,
invalid_block: Info,

cache: std.enums.EnumFieldStruct(CachedBlocks, Block, null) = undefined,
const CachedBlocks = enum { air, stone, dirt, grass };

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
        .models_dedup = .empty,
        .arena = .init(App.gpa()),
        .invalid_block = undefined,
    };
    try self.models_dedup.put(App.gpa(), .{}, {});
    self.invalid_block = .{
        .name = "invalid",
        .casts_ao = false,
        .solid = .initFull(true),
        .model = .initFull(&.{0}),
        .textures = .initFull(&.{self.atlas.get_missing()}),
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

    if (scanner.had_errors) {
        logger.warn("had errors while loading blocks...", .{});
    } else {
        logger.warn("loading blocks ok!", .{});
    }

    inline for (comptime std.enums.values(CachedBlocks)) |cached| {
        const name = std.fmt.comptimePrint(".blocks.main.{s}", .{@tagName(cached)});
        @field(self.cache, @tagName(cached)) = self.get_block_by_name(name);
    }

    return self;
}

pub fn deinit(self: *BlockManager) void {
    self.atlas.deinit();
    self.blocks.deinit(App.gpa());
    self.models.deinit(App.gpa());
    self.models_dedup.deinit(App.gpa());
    self.arena.deinit();
}

pub fn get_block_by_name(self: *BlockManager, name: []const u8) Block {
    const b = self.blocks.getIndex(name) orelse {
        logger.warn("missing block {s}", .{name});
        return Block.invalid;
    };
    return .{ .idx = .from_int(b) };
}

pub fn get_block_info(self: *BlockManager, block: Block) Info {
    if (block.idx == .invalid) {
        return self.invalid_block;
    } else {
        return self.blocks.values()[block.to_int(usize)];
    }
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

    blocks: std.StringArrayHashMapUnmanaged(ParsedBlock) = .empty,
    realized: std.StringArrayHashMapUnmanaged(ParsedBlock) = .empty,
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

    fn concat(
        self: *Builder,
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

        const gpa = self.arena.allocator();
        const res = try gpa.dupeZ(u8, buf.items);
        return res;
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
            const model_entry = try manager.models_dedup.getOrPut(App.gpa(), model);
            const name = try manager.arena.allocator().dupe(u8, entry.key_ptr.*);
            try manager.models.put(App.gpa(), name, model_entry.index);
            logger.info("registered model {s}@{d}", .{ name, model_entry.index });
        }
    }

    fn register_blocks(self: *Builder, manager: *BlockManager) !void {
        for (self.blocks.values()) |block| self.realize_block(block) catch |err| {
            logger.err("{s}: could not register block: {}", .{ block.name, err });
            self.had_errors = true;
        };
        for (self.realized.values()) |block| self.register_block(block, manager) catch |err| {
            logger.err("{s}: could not register block: {}", .{ block.name, err });
            self.had_errors = true;
        };
    }

    fn register_block(self: *Builder, block: ParsedBlock, manager: *BlockManager) !void {
        errdefer {
            logger.err("while registering {s}", .{block.name});
        }
        const b = self.realized.get(block.name).?;

        var info = Info{
            .name = try manager.arena.allocator().dupeZ(u8, b.name),
            .casts_ao = (try ParsedBlock.get_ensure_type(b.map.*, "casts_ao", .bool)).bool,
            .solid = .init(.{}),
            .model = .init(.{}),
            .textures = .init(.{}),
        };

        const solid: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "solid", .map)).map;
        const faces: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "faces", .map)).map;
        const textures: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "textures", .map)).map;
        const model: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "model", .map)).map;

        for (std.enums.values(Block.Face)) |face| {
            const s = (try ParsedBlock.get_ensure_type(solid, @tagName(face), .bool)).bool;
            info.solid.put(face, s);

            const face_model = (try ParsedBlock.get_ensure_type(model, @tagName(face), .key_list)).key_list;
            if (face_model.len % 2 != 0) {
                logger.err("model.{s} should be a list [model1, tex1, ...]", .{@tagName(face)});
                return error.TypeError;
            }
            const faces_buf = try manager.arena.allocator().alloc(usize, face_model.len / 2);
            const tex_buf = try manager.arena.allocator().alloc(usize, face_model.len / 2);

            for (0..face_model.len / 2) |i| {
                errdefer {
                    logger.err("while parsing model[{d}]", .{2 * i});
                }
                const model_local_name = face_model[2 * i];
                const tex_local_name = face_model[2 * i + 1];
                const model_global_name = (try ParsedBlock.get_ensure_type(faces, model_local_name, .str)).str;
                const tex_global_name = (try ParsedBlock.get_ensure_type(textures, tex_local_name, .str)).str;

                const model_idx = manager.models.get(model_global_name) orelse {
                    logger.err("missing model {s}", .{model_global_name});
                    return error.MissingData;
                };
                const tex_idx = manager.atlas.get_idx_or_warn(tex_global_name);

                faces_buf[i] = model_idx;
                tex_buf[i] = tex_idx;
            }

            info.model.put(face, faces_buf);
            info.textures.put(face, tex_buf);
        }

        try manager.blocks.put(App.gpa(), info.name, info);
        logger.info("registered block {s}", .{info.name});
    }

    const Error = OOM || error{ MissingData, TypeError, ValueTypeMismatch } || ParsedBlock.Error;
    fn realize_block(self: *Builder, block: ParsedBlock) Error!void {
        const name = block.name;
        if (self.realized.contains(name)) return;
        const gpa = self.arena.allocator();

        if (block.map.get("derives")) |base_name_val| {
            if (base_name_val.* != .str) {
                logger.err("{s}: 'derives' field should be a string", .{name});
                return error.TypeError;
            }
            const base_name = base_name_val.str;
            const base_unrealized = self.blocks.get(base_name) orelse {
                logger.err("{s}: missing data for base block '{s}'", .{ name, base_name });
                return error.MissingData;
            };
            try self.realize_block(base_unrealized);
            const base = self.realized.get(base_name).?;
            try ParsedBlock.derive(block.map, base.map.*, gpa);
        }

        try self.realized.put(App.gpa(), name, block);

        if (block.map.fetchSwapRemove("states")) |kv| {
            if (kv.value.* != .map) {
                logger.err("{s}: 'states' should be a kv-map field", .{name});
                return error.TypeError;
            }
            const states = &kv.value.map;
            for (states.keys(), states.values()) |state_name, state_val_orig| {
                const state_val = try state_val_orig.clone(gpa);
                if (state_val.* != .map) {
                    logger.err("{s}: states.{s} should be a kv-map", .{ name, state_name });
                    return error.TypeError;
                }
                const state_full_name = try std.fmt.allocPrintSentinel(
                    gpa,
                    "{s}:{s}",
                    .{ name, state_name },
                    0,
                );

                const state_block = ParsedBlock{ .map = &state_val.map, .name = state_full_name };
                const derives = try gpa.create(ParsedBlock.Value);
                derives.* = .{ .str = name };
                if (try state_block.map.fetchPut(gpa, "derives", derives)) |_| {
                    logger.err("{s}: 'derives' not allowed in sub-states", .{state_full_name});
                    self.had_errors = true;
                    continue;
                }

                _ = try self.realize_block(state_block);
            }

            try block.map.put(gpa, kv.key, kv.value);
        }
    }
};

const ParsedBlock = struct {
    name: []const u8,
    map: *Map,

    fn parse_and_store(
        builder: *Builder,
        dir: std.fs.Dir,
        prefix: []const []const u8,
        file_name: []const u8,
    ) !void {
        const ext: []const u8 = ".zon";
        if (!std.mem.eql(u8, ext, std.fs.path.extension(file_name))) return error.NotAZonFile;
        const name = file_name[0 .. file_name.len - ext.len];
        const map = try parse(builder, dir, file_name);
        const full_name = try builder.concat("blocks", prefix, name);
        try builder.blocks.put(App.gpa(), full_name, .{ .map = map, .name = full_name });
    }

    const Zon = std.zig.Zoir.Node;
    const Ctx = struct { ast: std.zig.Ast, zoir: std.zig.Zoir };

    fn get_ensure_type(map: Map, name: []const u8, typ: Tag) !*Value {
        const val = map.get(name) orelse {
            logger.err("missing field {s}", .{name});
            return error.MissingField;
        };
        const tag = @as(Tag, val.*);
        if (tag != typ) {
            logger.err("expected {}, got {}", .{ typ, tag });
            return error.TypeError;
        }
        return val;
    }

    fn parse(builder: *Builder, dir: std.fs.Dir, file_name: []const u8) !*Map {
        var file = try dir.openFile(file_name, .{});
        defer file.close();
        var buf = std.mem.zeroes([256]u8);
        var reader = file.reader(&buf);
        const size = try reader.getSize();
        const gpa = builder.arena.allocator();
        const src = try gpa.allocSentinel(u8, size, 0);
        try reader.interface.readSliceAll(src);

        const ast = try std.zig.Ast.parse(gpa, src, .zon);
        const ctx = Ctx{
            .ast = ast,
            .zoir = try std.zig.ZonGen.generate(gpa, ast, .{}),
        };
        if (ctx.zoir.hasCompileErrors()) {
            const stderr = std.debug.lockStderrWriter(&buf);
            defer std.debug.unlockStderrWriter();
            for (ctx.ast.errors) |err| {
                try ctx.ast.renderError(err, stderr);
            }
        }

        const val = try zon_to_map(ctx, .root, gpa);
        return &val.map;
    }

    const Error = OOM || error{ ExpectedStringLiteral, UnexpectedValue };
    fn zon_to_map(ctx: Ctx, node: Zon.Index, gpa: std.mem.Allocator) Error!*Value {
        errdefer {
            const ast_node = node.getAstNode(ctx.zoir);
            const tok = ctx.ast.nodeMainToken(ast_node);
            const loc = ctx.ast.tokenLocation(0, tok);
            logger.err(
                "at {d}:{d}\n{s}",
                .{ loc.line, loc.column, ctx.ast.source[loc.line_start..loc.line_end] },
            );
        }

        const val = try gpa.create(Value);
        const zon_node = node.get(ctx.zoir);
        switch (zon_node) {
            .empty_literal => {
                val.* = .{ .map = .empty };
            },
            .struct_literal => |x| {
                var map = Map.empty;
                for (x.names, 0..) |key, i| {
                    try map.put(
                        gpa,
                        key.get(ctx.zoir),
                        try zon_to_map(ctx, x.vals.at(@intCast(i)), gpa),
                    );
                }
                val.* = .{ .map = map };
            },
            .true => {
                val.* = .{ .bool = true };
            },
            .false => {
                val.* = .{ .bool = false };
            },
            .string_literal => |x| {
                val.* = .{ .str = x };
            },
            .array_literal => |x| {
                const arr = try gpa.alloc([]const u8, x.len);
                for (0..x.len) |i| {
                    const child = x.at(@intCast(i)).get(ctx.zoir);
                    switch (child) {
                        .string_literal => |y| arr[i] = y,
                        .enum_literal => |y| arr[i] = y.get(ctx.zoir),
                        else => return error.ExpectedStringLiteral,
                    }
                }
                val.* = .{ .key_list = arr };
            },
            else => return error.UnexpectedValue,
        }

        return val;
    }

    fn derive(derived: *Map, base: Map, gpa: std.mem.Allocator) !void {
        for (base.keys(), base.values()) |k, v| {
            errdefer {
                logger.err("at .{s}", .{k});
            }

            if (derived.get(k)) |existing| {
                const t1 = @as(Tag, existing.*);
                const t2 = @as(Tag, v.*);
                if (t1 != t2) {
                    logger.err("derive type error, expected {} got {}", .{ t1, t2 });
                    return error.ValueTypeMismatch;
                }
                switch (existing.*) {
                    .map => |*x| try derive(x, v.map, gpa),
                    else => {},
                }
            } else {
                try derived.put(gpa, k, try v.clone(gpa));
            }
        }
    }

    const Map = std.StringArrayHashMapUnmanaged(*Value);
    const Value = union(enum) {
        map: Map,
        str: []const u8,
        bool: bool,
        key_list: []const []const u8,

        fn clone(self: *Value, gpa: std.mem.Allocator) !*Value {
            switch (self.*) {
                .map => |x| {
                    var res = Map.empty;
                    for (x.keys(), x.values()) |k, v| {
                        try res.put(gpa, k, try v.clone(gpa));
                    }
                    const ptr = try gpa.create(Value);
                    ptr.* = .{ .map = res };
                    return ptr;
                },
                else => return self,
            }
        }
    };

    const Tag = std.meta.Tag(Value);
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
        const full_name = try builder.concat("blocks", prefix, name);
        try builder.models.put(App.gpa(), full_name, model);
    }
};

pub const Info = struct {
    name: [:0]const u8,
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
