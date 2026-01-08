const App = @import("App.zig");
const std = @import("std");
const c = @import("c.zig").c;

const BlockEditor = @This();

const Instance = struct {
    var instance: BlockEditor = .{};
};

pub fn instance() *BlockEditor {
    return &Instance.instance;
}

pub fn layer() App.Layer {
    return .{
        .data = @ptrCast(instance()),
        .on_attatch = @ptrCast(on_attach),
        .on_detatch = @ptrCast(on_detach),
    };
}

pub fn on_attach(self: *BlockEditor) App.UnhandledError!void {
    _ = self;
}

pub fn on_detach(self: *BlockEditor) App.UnhandledError!void {
    _ = self;
}
