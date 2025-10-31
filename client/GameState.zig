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
    self.ecs.deinit();
    self.keys.deinit();
}

pub fn on_frame_start(self: *GameState) !void {
    try self.keys.on_frame_start();
}

pub fn on_frame_end(self: *GameState) !void {
    try self.keys.on_frame_end();
}

pub fn update(self: *GameState) !void {
    try self.ecs.evaluate();
}
