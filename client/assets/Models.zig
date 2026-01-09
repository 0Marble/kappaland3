const Assets = @import("../Assets.zig");
const std = @import("std");
const VFS = @import("VFS.zig");
const Block = @import("../Block.zig");
const glTF = @import("glTF.zig");

const Models = @This();
const logger = std.log.scoped(.models);

gltfs: std.StringArrayHashMapUnmanaged(*glTF),
arena: std.heap.ArenaAllocator,
prefix: []const u8,

pub fn init(gpa: std.mem.Allocator, dir: *VFS.Dir) !Models {
    var self = Models{
        .arena = .init(gpa),
        .prefix = dir.path,
        .gltfs = .empty,
    };
    var ctx = BuildCtx{
        .temp = std.heap.ArenaAllocator.init(gpa),
        .ok = true,
        .prefix = dir.path,
    };
    defer ctx.temp.deinit();

    logger.info("loading models from {s}", .{dir.path});

    _ = dir.visit_no_fail(add_model, .{ &self, &ctx });

    if (ctx.ok) {
        logger.info("{s}: all models loaded successfully!", .{dir.path});
    } else {
        logger.warn("{s}: had errors while loading", .{dir.path});
    }

    return self;
}

pub fn deinit(self: *Models) void {
    for (self.gltfs.values()) |gltf| gltf.deinit();
    self.arena.deinit();
}

pub fn get(self: *Models, name: []const u8) ?*glTF {
    return self.gltfs.get(name);
}

fn add_model(self: *Models, ctx: *BuildCtx, file: *VFS.File) !void {
    errdefer ctx.ok = false;
    defer _ = ctx.temp.reset(.retain_capacity);

    var gltf = try glTF.init(self.arena.child_allocator, file);
    errdefer gltf.deinit();
    const name = try Assets.to_name(self.arena.allocator(), file.path);
    try self.gltfs.put(self.arena.allocator(), name, gltf);
    logger.info("registered model {s}", .{name});
}

const BuildCtx = struct {
    ok: bool,
    prefix: []const u8,
    temp: std.heap.ArenaAllocator,
};
