const std = @import("std");
const zm = @import("zm");

const NEAR = 0.1;

angles: @Vector(2, f32),
pos: @Vector(3, f32),
fov: f32,
aspect: f32,

mat_changed: bool = true,
cached_mat: zm.Mat4f = .zero(),
cached_inv: zm.Mat4f = .zero(),
cached_forward: zm.Vec3f = @splat(0),
cached_view: zm.Mat4f = .zero(),

const Frustum = @This();
pub fn init(fov: f32, aspect: f32) Frustum {
    return .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
    };
}

pub fn move(self: *Frustum, dx: zm.Vec3f) void {
    self.pos += dx;
    self.mat_changed = true;
}

pub fn rotate(self: *Frustum, d_angles: zm.Vec2f) void {
    self.angles -= d_angles;
    self.mat_changed = true;
}

pub fn update_fov(self: *Frustum, fov: f32) void {
    self.fov = fov;
    self.mat_changed = true;
}

pub fn update_aspect(self: *Frustum, aspect: f32) void {
    self.aspect = aspect;
    self.mat_changed = true;
}

fn recalculate(self: *Frustum) void {
    if (!self.mat_changed) return;
    const rot = zm.Mat4f.rotation(.{ 0, 1, 0 }, self.angles[1])
        .multiply(zm.Mat4f.rotation(.{ 1, 0, 0 }, self.angles[0]));
    self.cached_forward = zm.vec.xyz(rot.multiplyVec4(.{ 0, 0, -1, 1 }));
    const up = zm.vec.xyz(rot.multiplyVec4(.{ 0, 1, 0, 1 }));
    self.cached_view = zm.Mat4f.lookAt(self.pos, self.pos + self.cached_forward, up);
    self.cached_mat = self.proj_mat().multiply(self.cached_view);
    self.cached_inv = self.cached_mat.inverse();
    self.mat_changed = false;
}

pub fn vp_mat(self: *Frustum) zm.Mat4f {
    self.recalculate();
    return self.cached_mat;
}

pub fn view_mat(self: *Frustum) zm.Mat4f {
    self.recalculate();
    return self.cached_view;
}

pub fn proj_mat(self: *Frustum) zm.Mat4f {
    const f = 1.0 / @tan(self.fov * 0.5);
    const g = f / self.aspect;
    return zm.Mat4f{ .data = .{
        g, 0, 0,  0,
        0, f, 0,  0,
        0, 0, 0,  2 * NEAR,
        0, 0, -1, 0,
    } };
}

pub fn view_dir(self: *Frustum) zm.Vec3f {
    self.recalculate();
    return self.cached_forward;
}

pub fn inverse_vp(self: *Frustum) zm.Mat4f {
    self.recalculate();
    return self.cached_inv;
}

pub fn point_in_frustum(self: *Frustum, point: zm.Vec3f) bool {
    const mat = self.vp_mat();
    var ndc = mat.multiplyVec4(.{ point[0], point[1], point[2], 1.0 });
    ndc /= @splat(ndc[3]);
    return @abs(ndc[0]) < 1 and @abs(ndc[1]) < 1 and ndc[2] > 0;
}

// approximates the frustum as a cone
pub fn sphere_in_frustum(self: *Frustum, center: zm.Vec3f, radius: f32) bool {
    const fovy = std.math.atan(@tan(self.fov / 2) * self.aspect) * 2;
    const a = self.pos;
    const n = self.view_dir();
    const p = center;
    const alpha = @max(self.fov, fovy);
    const d_len = zm.vec.len(p - a);
    const t = zm.vec.dot(p - a, n);
    const beta = std.math.acos(t / d_len);
    const gamma = beta - alpha / 2;
    if (gamma < 0) return true;
    const dist = if (gamma >= std.math.pi * 0.5) d_len else d_len * @sin(gamma);
    return dist <= radius;
}

test "Frustum.point_in_frustum" {
    var f = Frustum.init(std.math.pi * 0.5, 1);

    try std.testing.expect(f.point_in_frustum(.{ 0, 0, -1 }));
    try std.testing.expect(f.point_in_frustum(.{ 0, 0, -10 }));
    try std.testing.expect(!f.point_in_frustum(.{ 0, 0, 1 }));
    try std.testing.expect(!f.point_in_frustum(.{ 0, 0, 10 }));

    try std.testing.expect(f.point_in_frustum(.{ 0.9, 0, -1 }));
    try std.testing.expect(!f.point_in_frustum(.{ 100, 0, -1 }));
    try std.testing.expect(f.point_in_frustum(.{ 99, 0, -100 }));
    try std.testing.expect(!f.point_in_frustum(.{ 101, 0, -100 }));
}

test "Frustum.sphere_in_frustum" {
    var f = Frustum.init(std.math.pi * 0.5, 1);

    try std.testing.expect(f.sphere_in_frustum(.{ 0, 0, -1 }, 1));
    try std.testing.expect(f.sphere_in_frustum(.{ 0, 0, -1 }, 10));
    try std.testing.expect(f.sphere_in_frustum(.{ 0, 0, -100 }, 10));

    try std.testing.expect(f.sphere_in_frustum(.{ 0, 0, 1 }, 2));
    try std.testing.expect(!f.sphere_in_frustum(.{ 0, 0, 1.5 }, 1));

    try std.testing.expect(f.sphere_in_frustum(.{ -11, 0, -10 }, 1.1));
    try std.testing.expect(!f.sphere_in_frustum(.{ -15, 0, -10 }, 1));
    try std.testing.expect(f.sphere_in_frustum(.{ -120 - 8 * @sqrt(3.0), 0, -120 }, 8 * @sqrt(3.0)));
}
