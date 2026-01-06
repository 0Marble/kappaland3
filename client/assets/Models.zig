const Assets = @import("../Assets.zig");
const std = @import("std");
const VFS = @import("VFS.zig");

const Models = @This();
const logger = std.log.scoped(.models);

name_to_model: std.StringArrayHashMapUnmanaged(usize),
models: std.AutoArrayHashMapUnmanaged(FaceModel, void),
arena: std.heap.ArenaAllocator,

pub fn init(gpa: std.mem.Allocator, dir: *VFS.Dir) !Models {
    var self = Models{
        .name_to_model = .empty,
        .models = .empty,
        .arena = .init(gpa),
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

    const name = try Assets.to_name(self.arena.allocator(), file.path);
    const entry = try self.models.getOrPut(self.arena.allocator(), model);
    try self.name_to_model.put(self.arena.allocator(), name, entry.index);
    logger.info("registered model {s}@{d}", .{ name, entry.index });
}

const BuildCtx = struct {
    ok: bool,
    prefix: []const u8,
    temp: std.heap.ArenaAllocator,
};
