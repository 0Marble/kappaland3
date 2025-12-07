const std = @import("std");
const zm = @import("zm");
const Frustum = @import("Frustum.zig");

w: usize,
h: usize,
grid: std.ArrayList(f32),

const Occlusion = @This();
pub fn init(gpa: std.mem.Allocator, w: usize, h: usize) !Occlusion {
    var self = Occlusion{
        .w = w,
        .h = h,
        .grid = .empty,
    };
    // glClipControl set to 0 (near) to 1 (far)
    try self.grid.appendNTimes(gpa, 1.0, w * h);

    return self;
}

pub fn clear(self: *Occlusion) void {
    self.grid.clearRetainingCapacity();
    self.grid.appendNTimesAssumeCapacity(1.0, self.w * self.h);
}

pub fn deinit(self: *Occlusion, gpa: std.mem.Allocator) void {
    self.grid.deinit(gpa);
}

fn aabb_points(self: *Occlusion, aabb: zm.AABBf, frustum: *Frustum) [8]zm.Vec3f {
    _ = self;

    const size = aabb.size();
    var pts: [8]zm.Vec3f = .{
        aabb.min + zm.Vec3f{ 0, 0, 0 } * size,
        aabb.min + zm.Vec3f{ 1, 0, 0 } * size,
        aabb.min + zm.Vec3f{ 0, 1, 0 } * size,
        aabb.min + zm.Vec3f{ 0, 0, 1 } * size,
        aabb.min + zm.Vec3f{ 1, 1, 0 } * size,
        aabb.min + zm.Vec3f{ 1, 0, 1 } * size,
        aabb.min + zm.Vec3f{ 0, 1, 1 } * size,
        aabb.min + zm.Vec3f{ 1, 1, 1 } * size,
    };
    for (&pts) |*x| {
        const y = frustum.vp_mat().multiplyVec4(.{ x[0], x[1], x[2], 1 });
        x.* = zm.vec.xyz(y / @as(zm.Vec4f, @splat(y[3])));
    }
    return pts;
}

pub fn add_occluder(self: *Occlusion, aabb: zm.AABBf, frustum: *Frustum) void {
    const pts = self.aabb_points(aabb, frustum);
    var center = zm.Vec2f{ 0, 0 };
    for (&pts) |x| center += zm.vec.xy(x);
    var furthest: f32 = 0;
    for (&pts) |x| furthest = @max(furthest, x[2]);

    center /= @splat(8.0);

    var rad_sq = std.math.inf(f32);
    for (&pts) |x| rad_sq = @min(rad_sq, zm.vec.lenSq(center - zm.vec.xy(x)));

    const grid_size = zm.Vec2f{
        @floatFromInt(self.w),
        @floatFromInt(self.h),
    };
    const cell_size = @as(zm.Vec2f, @splat(2.0)) / grid_size;

    for (0..self.h) |y| {
        outer: for (0..self.w) |x| {
            const xy: zm.Vec2f = @floatFromInt(@Vector(2, usize){ x, y });
            const a = (xy - grid_size / @as(zm.Vec2f, @splat(2))) * cell_size;
            const b = a + zm.Vec2f{ 1, 0 } * cell_size;
            const c = a + zm.Vec2f{ 0, 1 } * cell_size;
            const d = a + zm.Vec2f{ 1, 1 } * cell_size;

            inline for (.{ a, b, c, d }) |p| {
                const dist = zm.vec.lenSq(p - center);
                if (dist > rad_sq) continue :outer;
            }
            const idx = y * self.w + x;
            self.grid.items[idx] = @min(furthest, self.grid.items[idx]);
        }
    }
}

pub fn is_occluded(self: *Occlusion, aabb: zm.AABBf, frustum: *Frustum) bool {
    const pts = self.aabb_points(aabb, frustum);

    var min: zm.Vec2f = @splat(1);
    var max: zm.Vec2f = @splat(-1);
    var nearest: f32 = 1.0;
    for (pts) |x| {
        min = @min(min, zm.vec.xy(x));
        max = @max(max, zm.vec.xy(x));
        nearest = @min(nearest, x[2]);
    }

    min = std.math.clamp(min, zm.Vec2f{ -1, -1 }, zm.Vec2f{ 1, 1 });
    max = std.math.clamp(max, zm.Vec2f{ -1, -1 }, zm.Vec2f{ 1, 1 });

    const cell_size: zm.Vec2f = .{
        2.0 / @as(f32, @floatFromInt(self.w)),
        2.0 / @as(f32, @floatFromInt(self.h)),
    };
    const one: zm.Vec2f = @splat(1);
    const c0: @Vector(2, usize) = @intFromFloat(@floor((min + one) / cell_size));
    const c1: @Vector(2, usize) = @intFromFloat(@ceil((max + one) / cell_size));

    for (c0[1]..c1[1]) |y| {
        for (c0[0]..c1[0]) |x| {
            const idx = y * self.w + x;
            if (self.grid.items[idx] > nearest) return false;
        }
    }

    return true;
}
