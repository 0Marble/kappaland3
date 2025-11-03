const App = @import("App.zig");
const libmine = @import("libmine");
const Ecs = libmine.Ecs;
const Log = libmine.Log;
const std = @import("std");
const c = @import("c.zig").c;
const Camera = @import("Camera.zig");
const Keys = @import("Keys.zig");

ecs: Ecs,
keys: Keys,
camera: Camera,

const GameState = @This();
pub fn init(self: *GameState) !void {
    self.ecs = .init(App.gpa());
    try self.keys.init();
    try self.camera.init(std.math.pi * 0.5, 640.0 / 480.0);
}

pub fn deinit(self: *GameState) void {
    self.camera.deinit();
    self.keys.deinit();
    self.ecs.deinit();
}

pub fn on_frame_start(self: *GameState) !void {
    try App.gui().add_to_frame(GameState, "Debug", self, &struct {
        fn callback(this: *GameState) !void {
            const camera_str: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
                App.frame_alloc(),
                "xyz: {}, angles: {}",
                .{ this.camera.pos, this.camera.angles },
                0,
            ));
            c.igText("%s", camera_str);
        }
    }.callback, @src());

    try self.keys.on_frame_start();
}

pub fn on_frame_end(self: *GameState) !void {
    try self.keys.on_frame_end();
}

pub fn update(self: *GameState) !void {
    try self.ecs.evaluate();
}
