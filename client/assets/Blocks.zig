const std = @import("std");
const Assets = @import("../Assets.zig");
const VFS = @import("VFS.zig");
const TextureAtlas = @import("TextureAtlas.zig");
const Models = @import("Models.zig");
const Block = @import("../Block.zig");

const Blocks = @import("Blocks.zig");
const OOM = std.mem.Allocator.Error;
const logger = std.log.scoped(.blocks);

blocks: std.StringArrayHashMapUnmanaged(Info) = .empty,
models: std.AutoArrayHashMapUnmanaged(Block.Face, void) = .empty,
arena: std.heap.ArenaAllocator,

air: Block = undefined,
dirt: Block = undefined,
stone: Block = undefined,
grass: Block = undefined,

pub fn init(gpa: std.mem.Allocator, dir: *VFS.Dir, atlas: *TextureAtlas) !Blocks {
    logger.info("loading block data from {s}", .{dir.path});
    var self = Blocks{ .arena = .init(gpa) };

    var ctx = BuildCtx{
        .prefix = dir.path,
        .arena = .init(gpa),
        .blocks = &self,
        .atlas = atlas,
    };
    defer ctx.arena.deinit();
    _ = dir.visit_no_fail(BuildCtx.parse, .{&ctx});

    logger.info("realizing block data", .{});
    try ctx.realize_all();

    logger.info("registering block data", .{});
    try ctx.register_all();

    logger.info("caching common blocks", .{});
    self.air = self.get_block(".main.air");
    self.stone = self.get_block(".main.stone:block");
    self.dirt = self.get_block(".main.dirt");
    self.grass = self.get_block(".main.grass");

    if (ctx.ok) {
        logger.info("loading blocks: ok!", .{});
    } else {
        logger.warn("loading blocks: had errors", .{});
    }
    return self;
}

pub fn deinit(self: *Blocks) void {
    self.arena.deinit();
}

pub fn get_info(self: *Blocks, block: Block) Info {
    return self.blocks.values()[block.to_int(usize)];
}

pub fn get_block(self: *Blocks, name: []const u8) Block {
    if (self.blocks.getIndex(name)) |x| return .from_int(x);
    return self.get_invalid();
}

pub fn get_invalid(self: *Blocks) Block {
    return .from_int(self.blocks.getIndex(".main.default").?);
}

const BuildCtx = struct {
    ok: bool = true,
    parsed: std.StringArrayHashMapUnmanaged(ParsedBlock) = .empty,
    realized: std.StringArrayHashMapUnmanaged(ParsedBlock) = .empty,

    prefix: []const u8,
    arena: std.heap.ArenaAllocator,
    atlas: *TextureAtlas,
    blocks: *Blocks,

    fn parse(self: *BuildCtx, file: *VFS.File) !void {
        errdefer self.ok = false;
        const src = try file.read_all(self.arena.allocator());
        const zon = try src.parse_zon(self.arena.allocator());
        const value = try ParsedBlock.zon_to_map(zon, .root, self.arena.allocator());
        const block = ParsedBlock{
            .map = &value.map,
            .name = try Assets.to_name(self.arena.allocator(), file.path[self.prefix.len..]),
        };
        try self.parsed.put(self.arena.allocator(), block.name, block);
    }

    fn realize_all(self: *BuildCtx) !void {
        for (self.parsed.values()) |block| self.realize_block(block) catch |err| {
            logger.err("{s}: could not realize block: {}", .{ block.name, err });
            self.ok = false;
        };
    }

    fn register_all(self: *BuildCtx) !void {
        for (self.realized.values()) |block| self.register_block(block) catch |err| {
            logger.err("{s}: could not register block: {}", .{ block.name, err });
            self.ok = false;
        };
    }

    fn realize_block(self: *BuildCtx, block: ParsedBlock) !void {
        const name = block.name;
        if (self.realized.contains(name)) return;
        const gpa = self.arena.allocator();

        if (block.map.get("derives")) |base_name_val| {
            if (base_name_val.* != .str) {
                logger.err("{s}: 'derives' field should be a string", .{name});
                return error.TypeError;
            }
            const base_name = base_name_val.str;
            const base = if (self.realized.get(base_name)) |old|
                old
            else if (self.parsed.get(base_name)) |unrealized| blk: {
                try self.realize_block(unrealized);
                break :blk self.realized.get(base_name).?;
            } else {
                logger.err("{s}: missing data for base block '{s}'", .{ name, base_name });
                return error.MissingData;
            };
            try ParsedBlock.derive(block.map, base.map.*, gpa);
        }

        try self.realized.put(gpa, name, block);

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
                    self.ok = false;
                    continue;
                }

                _ = try self.realize_block(state_block);
            }

            try block.map.put(gpa, kv.key, kv.value);
        }
    }

    fn register_block(self: *BuildCtx, block: ParsedBlock) !void {
        if (block.map.contains("states")) return;
        errdefer logger.err("while registering {s}", .{block.name});

        const b = self.realized.get(block.name).?;

        var info = Info{
            .name = try self.blocks.arena.allocator().dupeZ(u8, b.name),
            .casts_ao = (try ParsedBlock.get_ensure_type(b.map.*, "casts_ao", .bool)).bool,
            .light_color = null,
            .solid = .init(.{}),
            .faces = .init(.{}),
            .textures = .init(.{}),
        };
        if (b.map.get("light_color")) |color| switch (color.*) {
            .u32 => |x| info.light_color = @intCast(x),
            else => return error.TypeError,
        };

        const solid: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "solid", .map)).map;
        const faces: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "faces", .map)).map;
        const textures: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(
            b.map.*,
            "textures",
            .map,
        )).map;
        const model: ParsedBlock.Map = (try ParsedBlock.get_ensure_type(b.map.*, "model", .map)).map;

        for (std.enums.values(Block.Direction)) |direction| {
            const s = (try ParsedBlock.get_ensure_type(solid, @tagName(direction), .bool)).bool;
            info.solid.put(direction, s);

            const face_model = (try ParsedBlock.get_ensure_type(
                model,
                @tagName(direction),
                .key_list,
            )).key_list;
            if (face_model.len % 2 != 0) {
                logger.err("model.{s} should be a list [model1, tex1, ...]", .{@tagName(direction)});
                return error.TypeError;
            }
            const faces_buf = try self.blocks.arena.allocator().alloc(usize, face_model.len / 2);
            const tex_buf = try self.blocks.arena.allocator().alloc(usize, face_model.len / 2);

            for (0..face_model.len / 2) |i| {
                errdefer logger.err("while parsing model[{d}]", .{2 * i});

                const face_local_name = face_model[2 * i];
                const tex_local_name = face_model[2 * i + 1];
                const tex_global_name = (try ParsedBlock.get_ensure_type(
                    textures,
                    tex_local_name,
                    .str,
                )).str;
                const face_map = (try ParsedBlock.get_ensure_type(
                    faces,
                    face_local_name,
                    .map,
                )).map;

                const size_str = (try ParsedBlock.get_ensure_type(
                    face_map,
                    "size",
                    .key_list,
                )).key_list;
                if (size_str.len != 2) {
                    logger.err("expected size to have 2 values", .{});
                    return error.InvalidName;
                }
                const u_size = std.meta.stringToEnum(Size, size_str[0]) orelse {
                    logger.err("invaid value of size: {s}", .{size_str[0]});
                    return error.InvalidName;
                };
                const v_size = std.meta.stringToEnum(Size, size_str[1]) orelse {
                    logger.err("invaid value of size: {s}", .{size_str[1]});
                    return error.InvalidName;
                };

                const offset_str = (try ParsedBlock.get_ensure_type(
                    face_map,
                    "offset",
                    .key_list,
                )).key_list;
                if (offset_str.len != 3) {
                    logger.err("expected offset to have 3 values", .{});
                    return error.InvalidName;
                }
                const u_offset = std.meta.stringToEnum(Offset, offset_str[0]) orelse {
                    logger.err("invaid value of offset: {s}", .{offset_str[0]});
                    return error.InvalidName;
                };
                const v_offset = std.meta.stringToEnum(Offset, offset_str[1]) orelse {
                    logger.err("invaid value of offset: {s}", .{offset_str[1]});
                    return error.InvalidName;
                };
                const w_offset = std.meta.stringToEnum(Offset, offset_str[2]) orelse {
                    logger.err("invaid value of offset: {s}", .{offset_str[2]});
                    return error.InvalidName;
                };
                const entry = try self.blocks.models.getOrPut(self.blocks.arena.allocator(), .{
                    .u_scale = @intFromEnum(u_size),
                    .v_scale = @intFromEnum(v_size),
                    .u_offset = @intFromEnum(u_offset),
                    .v_offset = @intFromEnum(v_offset),
                    .w_offset = @intFromEnum(w_offset),
                });

                const tex_idx = self.atlas.get_idx_or_warn(tex_global_name);

                faces_buf[i] = entry.index;
                tex_buf[i] = tex_idx;
            }

            info.faces.put(direction, faces_buf);
            info.textures.put(direction, tex_buf);
        }

        try self.blocks.blocks.put(self.blocks.arena.allocator(), info.name, info);
        logger.info("registered block {s}@{d}", .{ info.name, self.blocks.blocks.count() - 1 });
    }
};

const ParsedBlock = struct {
    name: []const u8,
    map: *Map,

    const ZonNode = std.zig.Zoir.Node.Index;
    fn zon_to_map(ctx: VFS.Zon, node: ZonNode, gpa: std.mem.Allocator) !*Value {
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
            .int_literal => {
                const num = try std.zon.parse.fromZoirNode(
                    u32,
                    gpa,
                    ctx.ast,
                    ctx.zoir,
                    node,
                    null,
                    .{},
                );
                val.* = .{ .u32 = num };
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
            errdefer logger.err("at .{s}", .{k});

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
        u32: u32,
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

    const Tag = std.meta.Tag(Value);
};

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

pub const Info = struct {
    name: [:0]const u8,
    casts_ao: bool,
    light_color: ?u24,
    solid: std.EnumMap(Block.Direction, bool) = .initFull(false),
    faces: std.EnumMap(Block.Direction, []const usize) = .initFull(&.{}),
    textures: std.EnumMap(Block.Direction, []const usize) = .initFull(&.{}),
};
