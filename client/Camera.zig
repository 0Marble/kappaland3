const std = @import("std");
const zm = @import("zm");
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Controller = @import("controller.zig").Controller(@This(), Controls);
const Scancode = @import("Keys.zig").Scancode;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");

const MAX_REACH = 10;

angles: @Vector(2, f32),
pos: @Vector(3, f32),
fov: f32,
aspect: f32,
controller: Controller,

mat_changed: bool,
cached_mat: zm.Mat4f,
cached_inv: zm.Mat4f,
cached_forward: zm.Vec3f,

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
};

pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .aspect = aspect,
        .fov = fov,
        .angles = @splat(0),
        .pos = @splat(0),
        .controller = undefined,
        .mat_changed = true,
        .cached_mat = .zero(),
        .cached_inv = .zero(),
        .cached_forward = @splat(0),
    };
    try self.controller.init(self);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_W), .front);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_A), .left);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_S), .back);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_D), .right);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_SPACE), .up);
    try self.controller.bind_keydown(.from_sdl(c.SDL_SCANCODE_LSHIFT), .down);

    try self.controller.bind_command(.front, .{ .normal = Camera.move });
    try self.controller.bind_command(.back, .{ .normal = Camera.move });
    try self.controller.bind_command(.left, .{ .normal = Camera.move });
    try self.controller.bind_command(.right, .{ .normal = Camera.move });
    try self.controller.bind_command(.up, .{ .normal = Camera.move });
    try self.controller.bind_command(.down, .{ .normal = Camera.move });
    try self.controller.bind_command(.move, .{ .mouse_move = Camera.look_around });
    try self.controller.bind_command(.interract, .{ .mouse_down = Camera.interract });
}

pub fn deinit(self: *Camera) void {
    self.controller.deinit();
}

pub fn interract(self: *Camera, _: Controls, btn: Keys.MouseDownEvent) void {
    if (btn.button == .middle) return;
    if (!App.key_state().is_mouse_just_down(btn.button)) return;

    const ray = zm.Rayf.init(self.pos, self.screen_to_world_dir(btn.px, btn.py));
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

pub fn look_around(self: *Camera, _: Controls, m: Keys.MouseMoveEvent) void {
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

fn recalculate(self: *Camera) void {
    if (!self.mat_changed) return;
    const rot = zm.Mat4f.rotation(.{ 0, 1, 0 }, self.angles[1])
        .multiply(zm.Mat4f.rotation(.{ 1, 0, 0 }, self.angles[0]));
    self.cached_forward = zm.vec.xyz(rot.multiplyVec4(.{ 0, 0, -1, 1 }));
    const up = zm.vec.xyz(rot.multiplyVec4(.{ 0, 1, 0, 1 }));
    // const proj = zm.Mat4f.perspective(self.fov, self.aspect, 1, 0);
    const f = 1.0 / @tan(self.fov * 0.5);
    const g = f / self.aspect;
    const near = 0.1;
    const proj = zm.Mat4f{ .data = .{
        g, 0, 0,  0,
        0, f, 0,  0,
        0, 0, 0,  near,
        0, 0, -1, 0,
    } };
    const view = zm.Mat4f.lookAt(self.pos, self.pos + self.cached_forward, up);
    self.cached_mat = proj.multiply(view);
    self.cached_inv = self.cached_mat.inverse();
    self.mat_changed = false;
}

pub fn as_mat(self: *Camera) zm.Mat4f {
    self.recalculate();
    return self.cached_mat;
}

pub fn view_dir(self: *Camera) zm.Vec3f {
    self.recalculate();
    return self.cached_forward;
}

pub fn inverse(self: *Camera) zm.Mat4f {
    self.recalculate();
    return self.cached_inv;
}

pub fn screen_to_world_dir(self: *Camera, px: f32, py: f32) zm.Vec3f {
    const w: f32 = @floatFromInt(App.screen_width());
    const h: f32 = @floatFromInt(App.screen_height());
    const x = 2 * (px / w) - 1;
    const y = 2 * ((h - py) / h) - 1;
    self.recalculate();
    return zm.vec.normalize(zm.vec.xyz(self.cached_inv.multiplyVec4(.{ x, y, 0, 1 })));
}

pub fn point_in_frustum(self: *Camera, point: zm.Vec3f) bool {
    const mat = self.as_mat();
    var ndc = mat.multiplyVec4(.{ point[0], point[1], point[2], 1.0 });
    ndc /= @splat(ndc[3]);
    return @abs(ndc[0]) < 1 and @abs(ndc[1]) < 1 and ndc[2] > 0;
}

test "Camera.point_in_frustum" {
    var cam = Camera{
        .angles = @splat(0),
        .aspect = 1,
        .fov = std.math.pi * 0.5,
        .pos = @splat(0),
        .mat_changed = true,
        .cached_forward = @splat(0),
        .cached_inv = .zero(),
        .cached_mat = .zero(),
        .controller = undefined,
    };

    try std.testing.expect(cam.point_in_frustum(.{ 0, 0, -1 }));
    try std.testing.expect(cam.point_in_frustum(.{ 0, 0, -10 }));
    try std.testing.expect(!cam.point_in_frustum(.{ 0, 0, 1 }));
    try std.testing.expect(!cam.point_in_frustum(.{ 0, 0, 10 }));

    try std.testing.expect(cam.point_in_frustum(.{ 0.9, 0, -1 }));
    try std.testing.expect(!cam.point_in_frustum(.{ 100, 0, -1 }));
    try std.testing.expect(cam.point_in_frustum(.{ 99, 0, -100 }));
    try std.testing.expect(!cam.point_in_frustum(.{ 101, 0, -100 }));
}
