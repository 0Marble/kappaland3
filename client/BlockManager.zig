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
    inline for (comptime std.enums.values(CachedBlocks)) |cached| {
        const name = std.fmt.comptimePrint(".blocks.main.{s}", .{@tagName(cached)});
        @field(self.cache, @tagName(cached)) = self.get_block_by_name(name);
    }

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

    blocks: std.StringArrayHashMapUnmanaged(*ParsedBlock) = .empty,
    models: std.StringArrayHashMapUnmanaged(ParsedModel) = .empty,

    fn deinit(self: *Builder) void {
        self.prefix.deinit(App.gpa());
        self.blocks.deinit(App.gpa());
        self.models.deinit(App.gpa());
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
        _ = self; // autofix
        _ = manager; // autofix
    }
};

const ParsedBlock = struct {
    fn parse_and_store(
        builder: *Builder,
        dir: std.fs.Dir,
        prefix: []const []const u8,
        file_name: []const u8,
    ) !void {
        _ = builder; // autofix
        _ = dir; // autofix
        _ = prefix; // autofix
        _ = file_name; // autofix
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
