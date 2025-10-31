const std = @import("std");
const zm = @import("zm");
const c = @import("c.zig").c;
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Controller = @import("Controller.zig");

angles: @Vector(2, f32),
pos: @Vector(3, f32),
fov: f32,
aspect: f32,
controller: Controller,

mat_changed: bool,
cached_mat: zm.Mat4f,

const Camera = @This();
pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
        .mat_changed = true,
        .cached_mat = .zero(),
        .controller = .init,
    };
    try self.controller.attatch(Camera, self);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_W, Camera.move_forward);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_S, Camera.move_forward);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_A, Camera.move_right);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_D, Camera.move_right);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_SPACE, Camera.move_up);
    try self.controller.bind_keydown(Camera, c.SDL_SCANCODE_LSHIFT, Camera.move_up);
}

pub fn move_forward(self: *Camera, key: c.SDL_Scancode) void {
    const amt = if (key == c.SDL_SCANCODE_W) App.frametime() * 0.01 else -App.frametime() * 0.01;
    const dir = @Vector(3, f32){
        @sin(-self.angles[1]),
        0,
        -@cos(-self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
    self.mat_changed = true;
}

pub fn move_right(self: *Camera, key: c.SDL_Scancode) void {
    const amt = if (key == c.SDL_SCANCODE_D) App.frametime() * 0.01 else -App.frametime() * 0.01;
    const dir = @Vector(3, f32){
        @cos(-self.angles[1]),
        0,
        @sin(-self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
    self.mat_changed = true;
}

pub fn move_up(self: *Camera, key: c.SDL_Scancode) void {
    const amt = if (key == c.SDL_SCANCODE_SPACE) App.frametime() * 0.01 else -App.frametime() * 0.01;
    const dir = @Vector(3, f32){ 0, 1, 0 };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
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
