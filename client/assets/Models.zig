const Assets = @import("../Assets.zig");
const std = @import("std");
const VFS = @import("VFS.zig");
const Block = @import("../Block.zig");

const Models = @This();
const logger = std.log.scoped(.models);

name_to_model: std.StringArrayHashMapUnmanaged(usize),
models: std.AutoArrayHashMapUnmanaged(Block.Model, void),
arena: std.heap.ArenaAllocator,
prefix: []const u8,

pub fn init(gpa: std.mem.Allocator, dir: *VFS.Dir) !Models {
    var self = Models{
        .name_to_model = .empty,
        .models = .empty,
        .arena = .init(gpa),
        .prefix = dir.path,
    };
    var ctx = BuildCtx{
        .temp = std.heap.ArenaAllocator.init(gpa),
        .ok = true,
        .prefix = dir.path,
    };
    defer ctx.temp.deinit();

    logger.info("loading models from {s}", .{dir.path});

    try dir.visit(add_model, .{ &self, &ctx });

    if (ctx.ok) {
        logger.info("{s}: all models loaded successfully!", .{dir.path});
    } else {
        logger.warn("{s}: had errors while loading", .{dir.path});
    }

    return self;
}

pub fn deinit(self: *Models) void {
    self.arena.deinit();
}

pub fn get_idx_or_warn(self: *Models, name: []const u8) usize {
    if (self.name_to_model.get(name)) |x| return x;
    logger.warn("missing model: {s}", .{name});
    return self.missing_model();
}

pub fn missing_model(self: *Models) usize {
    return self.name_to_model.get(".blocks.main.default").?;
}

const ModelKind = enum {
    face_model,
};

const FaceModel = struct {
    kind: ModelKind,
    size: struct { Size, Size },
    offset: struct { Offset, Offset, Offset },

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
};

fn add_model(self: *Models, ctx: *BuildCtx, file: *VFS.File) !void {
    errdefer ctx.ok = false;
    defer _ = ctx.temp.reset(.retain_capacity);
    const zon = try (try file.read_all(ctx.temp.allocator())).parse_zon(ctx.temp.allocator());
    const model = try zon.parse(FaceModel, ctx.temp.allocator());

    const name = try Assets.to_name(self.arena.allocator(), file.path[self.prefix.len..]);
    const entry = try self.models.getOrPut(self.arena.allocator(), .{
        .u_scale = @intFromEnum(model.size[0]),
        .v_scale = @intFromEnum(model.size[1]),
        .u_offset = @intFromEnum(model.offset[0]),
        .v_offset = @intFromEnum(model.offset[1]),
        .w_offset = @intFromEnum(model.offset[2]),
    });
    try self.name_to_model.put(self.arena.allocator(), name, entry.index);
    logger.info("registered model {s}@{d}", .{ name, entry.index });
}

const BuildCtx = struct {
    ok: bool,
    prefix: []const u8,
    temp: std.heap.ArenaAllocator,
};
