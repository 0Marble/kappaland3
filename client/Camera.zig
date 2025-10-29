const std = @import("std");
const zm = @import("zm");

angles: @Vector(2, f32),
pos: @Vector(3, f32),
fov: f32,
aspect: f32,

mat_changed: bool,
cached_mat: zm.Mat4f,

const Camera = @This();
pub fn init(fov: f32, aspect: f32) Camera {
    return .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
        .mat_changed = true,
        .cached_mat = .zero(),
    };
}

pub fn move_forward(self: *Camera, amt: f32) void {
    const dir: @Vector(3, f32) = .{
        -@sin(self.angles[1]),
        0,
        @cos(self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
}

pub fn move_horiz(self: *Camera, amt: f32) void {
    const dir: @Vector(3, f32) = .{
        @cos(self.angles[1]),
        0,
        @sin(self.angles[1]),
    };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
}

pub fn move_vert(self: *Camera, amt: f32) void {
    const dir: @Vector(3, f32) = .{ 0, 1, 0 };
    self.pos += dir * @as(@Vector(3, f32), @splat(amt));
}

pub fn turn_horiz(self: *Camera, amt: f32) void {
    self.angles[1] += amt;
}

pub fn turn_vert(self: *Camera, amt: f32) void {
    self.angles[0] += amt;
}

pub fn as_mat(self: *Camera) zm.Mat4f {
    if (!self.mat_changed) return self.cached_mat;
    return self.cached_mat;
}
