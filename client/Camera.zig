const std = @import("std");
const zm = @import("zm");
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Controller = @import("controller.zig").Controller(@This(), Controls);
const Scancode = @import("Keys.zig").Scancode;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");

angles: @Vector(2, f32),
pos: @Vector(3, f32),
fov: f32,
aspect: f32,
controller: Controller,

mat_changed: bool,
cached_mat: zm.Mat4f,

const Camera = @This();
const Controls = enum(u32) {
    front,
    back,
    left,
    right,
    up,
    down,
    move,
};

pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
        .mat_changed = true,
        .cached_mat = .zero(),
        .controller = undefined,
    };
    try self.controller.init(self);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_W), .front);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_A), .left);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_S), .back);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_D), .right);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_SPACE), .up);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_LSHIFT), .down);

    try self.controller.bind_command(.front, .{ .keydown = Camera.move });
    try self.controller.bind_command(.back, .{ .keydown = Camera.move });
    try self.controller.bind_command(.left, .{ .keydown = Camera.move });
    try self.controller.bind_command(.right, .{ .keydown = Camera.move });
    try self.controller.bind_command(.up, .{ .keydown = Camera.move });
    try self.controller.bind_command(.down, .{ .keydown = Camera.move });
    try self.controller.bind_command(.move, .{ .mouse_move = Camera.look_around });
}

pub fn deinit(self: *Camera) void {
    self.controller.deinit();
}

pub fn move(self: *Camera, cmd: Controls) void {
    const dir: @Vector(3, f32) = switch (cmd) {
        .front => .{
            @sin(-self.angles[1]),
            0,
            -@cos(-self.angles[1]),
        },
        .back => .{
            -@sin(-self.angles[1]),
            0,
            @cos(-self.angles[1]),
        },
        .right => .{
            @cos(-self.angles[1]),
            0,
            @sin(-self.angles[1]),
        },
        .left => .{
            -@cos(-self.angles[1]),
            0,
            -@sin(-self.angles[1]),
        },
        .up => .{ 0, 1, 0 },
        .down => .{ 0, -1, 0 },
        else => unreachable,
    };
    const speed: f32 = if (App.key_state().is_key_down(.from_sdl(c.SDL_SCANCODE_LCTRL))) 0.05 else 0.01;
    const amt = App.frametime() * speed;
    self.pos = @mulAdd(@Vector(3, f32), dir, @splat(amt), self.pos);
    self.mat_changed = true;
}

pub fn look_around(self: *Camera, _: Controls, m: Keys.OnMouseMove.Move) void {
    if (App.key_state().is_mouse_down(.middle)) {
        const amt = App.frametime() * 0.001;
        self.angles[0] -= m.dy * amt;
        self.angles[1] -= m.dx * amt;
        self.mat_changed = true;
    }
}

pub fn update_fov(self: *Camera, fov: f32) void {
    self.fov = fov;
    self.mat_changed = true;
}
pub fn update_aspect(self: *Camera, aspect: f32) void {
    self.aspect = aspect;
    self.mat_changed = true;
}

pub fn as_mat(self: *Camera) zm.Mat4f {
    if (self.mat_changed) {
        const rot = zm.Mat4f.rotation(.{ 0, 1, 0 }, self.angles[1]).multiply(zm.Mat4f.rotation(.{ 1, 0, 0 }, self.angles[0]));
        const forward = zm.vec.xyz(rot.multiplyVec4(.{ 0, 0, -1, 1 }));
        const up = zm.vec.xyz(rot.multiplyVec4(.{ 0, 1, 0, 1 }));
        const proj = zm.Mat4f.perspective(self.fov, self.aspect, 0.1, 1000.0);
        const view = zm.Mat4f.lookAt(self.pos, self.pos + forward, up);
        self.cached_mat = proj.multiply(view);
        self.mat_changed = false;
    }
    return self.cached_mat;
}
