const App = @import("App.zig");
const std = @import("std");
const Camera = @import("Camera.zig");
const c = @import("c.zig").c;
const Renderer = @import("Renderer.zig");
pub const ChunkManager = @import("ChunkManager.zig");
const Options = @import("ClientOptions");
const Coords = @import("Chunk.zig").Coords;

const Game = @This();
const WIDTH = Options.world_size;
const HEIGHT = Options.world_height;

camera: Camera,
renderer: Renderer,
chunk_manager: *ChunkManager,

const Instance = struct {
    var instance: Game = undefined;
};

pub fn layer() App.Layer {
    return App.Layer{
        .data = @ptrCast(&Instance.instance),
        .on_attatch = @ptrCast(&on_attatch),
        .on_frame_start = @ptrCast(&on_frame_start),
        .on_update = @ptrCast(&on_update),
        .on_frame_end = @ptrCast(&on_frame_end),
        .on_detatch = @ptrCast(&on_detatch),
    };
}

pub fn instance() *Game {
    return &Instance.instance;
}

fn on_attatch(self: *Game) !void {
    std.log.info("{*}: Attatched", .{self});
    self.camera.init(std.math.pi * 0.5, 1.0) catch |err| {
        std.debug.panic("TODO: controls should be set up in Settings/Keys: {}", .{err});
    };
    try self.renderer.init();
    self.chunk_manager = try ChunkManager.init(null);

    for (0..WIDTH) |i| {
        for (0..HEIGHT) |j| {
            for (0..WIDTH) |k| {
                var xyz: Coords = .{ @intCast(i), @intCast(j), @intCast(k) };
                xyz -= .{ WIDTH / 2, HEIGHT - 1, WIDTH / 2 };

                try self.chunk_manager.load(xyz);
            }
        }
    }
}

fn on_imgui(self: *Game) !void {
    const camera_str: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        "xyz: {:.3}, angles: {:.3}, view: {:.3}",
        .{
            self.camera.frustum.pos,
            self.camera.frustum.angles,
            self.camera.frustum.view_dir(),
        },
        0,
    ));
    c.igText("%s", camera_str);
    try self.chunk_manager.on_imgui();
}

fn on_frame_start(self: *Game) App.UnhandledError!void {
    try App.gui().add_to_frame(Game, "Debug", self, on_imgui, @src());
}

fn on_update(self: *Game) App.UnhandledError!void {
    try self.chunk_manager.process();
}

fn on_frame_end(self: *Game) App.UnhandledError!void {
    _ = self;
}

fn on_detatch(self: *Game) void {
    std.log.info("{*}: Detatched", .{self});
    self.camera.deinit();
    self.renderer.deinit();
    self.chunk_manager.deinit();
}
