const std = @import("std");
const zm = @import("zm");
const App = @import("App.zig");
const Scancode = @import("Keys.zig").Scancode;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");
const Math = @import("libmine").Math;
pub const Frustum = @import("Frustum.zig");
const Options = @import("ClientOptions");

const MAX_REACH = 10;

frustum: Frustum,
other_frustum: Frustum, // use to detatch occlusion from view for debug
frustum_for_occlusion: *Frustum,

const Camera = @This();

pub fn init(self: *Camera, fov: f32, aspect: f32) !void {
    self.* = .{
        .frustum = .init(fov, aspect),
        .other_frustum = undefined,
        .frustum_for_occlusion = undefined,
    };
    self.frustum_for_occlusion = &self.frustum;

    try App.key_state().register_action(".main.keys.hit");
    try App.key_state().bind_action(".main.keys.hit", .{ .button = .left });
    try App.key_state().on_action(".main.keys.hit", interact, .{ self, Keys.MouseButton.left });

    try App.key_state().register_action(".main.keys.place");
    try App.key_state().bind_action(".main.keys.place", .{ .button = .right });
    try App.key_state().on_action(".main.keys.place", interact, .{ self, Keys.MouseButton.right });

    try App.key_state().register_action(".main.keys.look_around");
    try App.key_state().bind_action(".main.keys.look_around", .{ .mouse_move = {} });
    try App.key_state().on_action(".main.keys.look_around", look_around, .{self});

    inline for (comptime std.meta.tags(Dir), .{ .W, .S, .D, .A, .SPACE, .LSHIFT }) |dir, key| {
        const name = ".main.keys.walk." ++ @tagName(dir);
        try App.key_state().register_action(name);
        try App.key_state().bind_action(
            name,
            .{ .scancode = .from_sdl(@field(c, "SDL_SCANCODE_" ++ @tagName(key))) },
        );
        try App.key_state().on_action(name, move, .{ self, dir });
    }

    try App.key_state().register_action(".main.keys.detatch");
    try App.key_state().bind_action(
        ".main.keys.detatch",
        .{ .scancode = .from_sdl(c.SDL_SCANCODE_LEFTBRACKET) },
    );
    try App.key_state().on_action(".main.keys.detatch", detatch, .{self});
}

pub fn deinit(self: *Camera) void {
    _ = self;
}

fn interact(self: *Camera, button: Keys.MouseButton, _: []const u8) void {
    const m = App.key_state().mouse_pos();
    if (!App.key_state().is_mouse_just_down(button)) return;
    const ray = zm.Rayf.init(self.frustum.pos, self.screen_to_world_dir(m.px, m.py));
    const raycast = App.game_state().world.raycast(ray, MAX_REACH) orelse return;

    if (button == .left) {
        App.game_state().world.set_block(raycast.hit_coords, .air) catch |err| {
            std.log.warn("{*}: Could not place block: {}", .{ self, err });
        };
    } else if (button == .right) {
        App.game_state().world.set_block(raycast.prev_coords, .stone) catch |err| {
            std.log.warn("{*}: Could not place block: {}", .{ self, err });
        };
    }
}

fn detatch(self: *Camera, _: []const u8) void {
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

const Dir = enum { front, back, right, left, up, down };

fn move(self: *Camera, cmd: Dir, _: []const u8) void {
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
    };

    const speed: f32 = if (App.key_state().is_key_pressed(.from_sdl(c.SDL_SCANCODE_LCTRL)))
        0.05
    else
        0.01;
    const amt = App.frametime() * speed;
    self.frustum.move(dir * @as(zm.Vec3f, @splat(amt)));
}

fn look_around(self: *Camera, _: []const u8) void {
    if (App.key_state().is_mouse_down(.middle)) {
        const m = App.key_state().mouse_pos();
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
