const std = @import("std");
const zm = @import("zm");
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Controller = @import("controller.zig").Controller(@This(), Controls);
const Scancode = @import("Keys.zig").Scancode;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");
const Math = @import("libmine").Math;
pub const Frustum = @import("Frustum.zig");
pub const Occlusion = @import("Occlusion.zig");

const MAX_REACH = 10;

controller: Controller,
frustum: Frustum,

other_frustum: Frustum, // use to detatch occlusion from view for debug
frustum_for_occlusion: *Frustum,
occlusion: Occlusion,

const Camera = @This();
const Controls = enum(u32) {
    front,
    back,
    left,
    right,
    up,
    down,
    move,
    interract,
    detatch,
};

pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .frustum = .init(fov, aspect),
        .other_frustum = undefined,
        .frustum_for_occlusion = undefined,
        .occlusion = try .init(App.gpa(), 8, 8),
        .controller = undefined,
    };
    self.frustum_for_occlusion = &self.frustum;

    try self.controller.init(self);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_W), .front);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_A), .left);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_S), .back);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_D), .right);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_SPACE), .up);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_LSHIFT), .down);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_LEFTBRACKET), .detatch);

    try self.controller.bind_command(.front, .{ .normal = Camera.move });
    try self.controller.bind_command(.back, .{ .normal = Camera.move });
    try self.controller.bind_command(.left, .{ .normal = Camera.move });
    try self.controller.bind_command(.right, .{ .normal = Camera.move });
    try self.controller.bind_command(.up, .{ .normal = Camera.move });
    try self.controller.bind_command(.down, .{ .normal = Camera.move });
    try self.controller.bind_command(.move, .{ .mouse_move = Camera.look_around });
    try self.controller.bind_command(.interract, .{ .mouse_down = Camera.interract });
    try self.controller.bind_command(.detatch, .{ .normal = Camera.detatch });
}

pub fn deinit(self: *Camera) void {
    self.occlusion.deinit(App.gpa());
    self.controller.deinit();
}

pub fn interract(self: *Camera, _: Controls, btn: Keys.MouseDownEvent) void {
    if (btn.button == .middle) return;
    if (!App.key_state().is_mouse_just_down(btn.button)) return;

    const ray = zm.Rayf.init(self.frustum.pos, self.screen_to_world_dir(btn.px, btn.py));
    const raycast = App.game_state().world.raycast(ray, MAX_REACH) orelse return;

    if (btn.button == .left) {
        App.game_state().world.request_set_block(raycast.hit_coords, .air) catch |err| {
            Log.log(.warn, "{*}: Could not place block: {}", .{ self, err });
        };
    } else if (btn.button == .right) {
        App.game_state().world.request_set_block(raycast.prev_coords, .stone) catch |err| {
            Log.log(.warn, "{*}: Could not place block: {}", .{ self, err });
        };
    }
}

fn detatch(self: *Camera, _: Controls) void {
    if (!App.key_state().is_key_just_pressed(.from_sdl(c.SDL_SCANCODE_LEFTBRACKET))) return;

    if (self.frustum_for_occlusion == &self.frustum) {
        self.other_frustum = .init(self.frustum.fov, self.frustum.aspect);
        self.other_frustum.pos = self.frustum.pos;
        self.other_frustum.angles = self.frustum.angles;

        self.frustum_for_occlusion = &self.other_frustum;
    } else {
        self.frustum_for_occlusion = &self.frustum;
    }
}

pub fn move(self: *Camera, cmd: Controls) void {
    const dir: @Vector(3, f32) = switch (cmd) {
        .front => .{
            @sin(-self.frustum.angles[1]),
            0,
            -@cos(-self.frustum.angles[1]),
        },
        .back => .{
            -@sin(-self.frustum.angles[1]),
            0,
            @cos(-self.frustum.angles[1]),
        },
        .right => .{
            @cos(-self.frustum.angles[1]),
            0,
            @sin(-self.frustum.angles[1]),
        },
        .left => .{
            -@cos(-self.frustum.angles[1]),
            0,
            -@sin(-self.frustum.angles[1]),
        },
        .up => .{ 0, 1, 0 },
        .down => .{ 0, -1, 0 },
        else => unreachable,
    };

    const speed: f32 = if (App.key_state().is_key_down(.from_sdl(c.SDL_SCANCODE_LCTRL)))
        0.05
    else
        0.01;
    const amt = App.frametime() * speed;
    self.frustum.move(dir * @as(zm.Vec3f, @splat(amt)));
}

pub fn look_around(self: *Camera, _: Controls, m: Keys.MouseMoveEvent) void {
    if (App.key_state().is_mouse_down(.middle)) {
        const amt = App.frametime() * 0.001;
        self.frustum.rotate(.{ m.dy * amt, m.dx * amt });
    }
}

pub fn screen_to_world_dir(self: *Camera, px: f32, py: f32) zm.Vec3f {
    const w: f32 = @floatFromInt(App.screen_width());
    const h: f32 = @floatFromInt(App.screen_height());
    const x = 2 * (px / w) - 1;
    const y = 2 * ((h - py) / h) - 1;
    return zm.vec.normalize(zm.vec.xyz(self.inverse_vp().multiplyVec4(.{ x, y, 0, 1 })));
}

pub fn vp_mat(self: *Camera) zm.Mat4f {
    return self.frustum.vp_mat();
}

pub fn view_mat(self: *Camera) zm.Mat4f {
    return self.frustum.view_mat();
}

pub fn proj_mat(self: *Camera) zm.Mat4f {
    return self.frustum.proj_mat();
}

pub fn view_dir(self: *Camera) zm.Vec3f {
    return self.frustum.view_dir();
}

pub fn inverse_vp(self: *Camera) zm.Mat4f {
    return self.frustum.inverse_vp();
}

pub fn point_in_frustum(self: *Camera, point: zm.Vec3f) bool {
    return self.frustum_for_occlusion.point_in_frustum(point);
}

pub fn sphere_in_frustum(self: *Camera, center: zm.Vec3f, radius: f32) bool {
    return self.frustum_for_occlusion.sphere_in_frustum(center, radius);
}

pub fn clear_occlusion(self: *Camera) void {
    self.occlusion.clear();
}

pub fn is_occluded(self: *Camera, aabb: zm.AABBf) bool {
    return self.occlusion.is_occluded(aabb, self.frustum_for_occlusion);
}

pub fn add_occluder(self: *Camera, aabb: zm.AABBf) void {
    self.occlusion.add_occluder(aabb, self.frustum_for_occlusion);
}
