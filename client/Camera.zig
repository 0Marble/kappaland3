const std = @import("std");
const zm = @import("zm");
const c = @import("c.zig").c;
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Controller = @import("controller.zig").Controller(@This(), Controls);

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
};

pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
        .mat_changed = true,
        .cached_mat = .zero(),
        .controller = try .init(self),
    };
    try self.controller.bind_keydown(c.SDL_SCANCODE_W, .front);
    try self.controller.bind_keydown(c.SDL_SCANCODE_A, .left);
    try self.controller.bind_keydown(c.SDL_SCANCODE_S, .back);
    try self.controller.bind_keydown(c.SDL_SCANCODE_D, .right);
    try self.controller.bind_keydown(c.SDL_SCANCODE_SPACE, .up);
    try self.controller.bind_keydown(c.SDL_SCANCODE_LSHIFT, .down);

    try self.controller.bind_command(.front, .{ .keydown = Camera.move_forward });
    try self.controller.bind_command(.back, .{ .keydown = Camera.move_forward });
    try self.controller.bind_command(.left, .{ .keydown = Camera.move_right });
    try self.controller.bind_command(.right, .{ .keydown = Camera.move_right });
    try self.controller.bind_command(.up, .{ .keydown = Camera.move_up });
    try self.controller.bind_command(.down, .{ .keydown = Camera.move_up });
}

pub fn deinit(self: *Camera) void {
    self.controller.deinit();
}

pub fn move_forward(self: *Camera, key: Controls) void {
    const amt = App.frametime() * 0.01;
    const mul = if (key == .front) amt else -amt;
    const dir = @Vector(3, f32){
        @sin(-self.angles[1]),
        0,
        -@cos(-self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(mul));
    self.mat_changed = true;
}

pub fn move_right(self: *Camera, key: Controls) void {
    const amt = App.frametime() * 0.01;
    const mul = if (key == .right) amt else -amt;
    const dir = @Vector(3, f32){
        @cos(-self.angles[1]),
        0,
        @sin(-self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(mul));
    self.mat_changed = true;
}

pub fn move_up(self: *Camera, key: Controls) void {
    const amt = App.frametime() * 0.01;
    const mul = if (key == .up) amt else -amt;
    const dir = @Vector(3, f32){ 0, 1, 0 };
    self.pos += dir * @as(@Vector(3, f32), @splat(mul));
    self.mat_changed = true;
}

pub fn turn_right(self: *Camera, amt: f32) void {
    self.angles[1] -= amt;
    self.mat_changed = true;
}

pub fn turn_up(self: *Camera, amt: f32) void {
    self.angles[0] -= amt;
    self.mat_changed = true;
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
        const proj = zm.Mat4f.perspective(self.fov, self.aspect, 0.1, 100.0);
        const view = zm.Mat4f.lookAt(self.pos, self.pos + forward, up);
        self.cached_mat = proj.multiply(view);
        self.mat_changed = false;
    }
    return self.cached_mat;
}
