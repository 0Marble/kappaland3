const App = @import("App.zig");
const libmine = @import("libmine");
const Ecs = libmine.Ecs;
const Log = libmine.Log;
const std = @import("std");
const c = @import("c.zig").c;
const Camera = @import("Camera.zig");
const World = @import("World.zig");
const Keys = @import("Keys.zig");

ecs: Ecs,
keys: Keys,
camera: Camera,
world: World,

const GameState = @This();
pub fn init(self: *GameState) !void {
    self.ecs = .init(App.gpa());
    try self.keys.init();
    try self.camera.init(std.math.pi * 0.5, 640.0 / 480.0);
    try self.world.init();
}

pub fn deinit(self: *GameState) void {
    self.camera.deinit();
    self.keys.deinit();
    self.ecs.deinit();
    self.world.deinit();
}

pub fn on_frame_start(self: *GameState) !void {
    try App.gui().add_to_frame(GameState, "Debug", self, &struct {
        fn callback(this: *GameState) !void {
            const camera_str: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
                App.frame_alloc(),
                "xyz: {:.3}, angles: {:.3}, view: {:.3}",
                .{
                    this.camera.frustum.pos,
                    this.camera.frustum.angles,
                    this.camera.frustum.view_dir(),
                },
                0,
            ));
            c.igText("%s", camera_str);
        }
    }.callback, @src());

    try self.keys.on_frame_start();
    try self.world.on_frame_start();
    self.camera.clear_occlusion();
}

pub fn on_frame_end(self: *GameState) !void {
    try self.keys.on_frame_end();
}

pub fn update(self: *GameState) !void {
    try self.ecs.evaluate();
    try self.world.process_work();
}
