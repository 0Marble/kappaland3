const App = @import("App.zig");
const Log = @import("libmine").Log;
const std = @import("std");
const c = @import("c.zig").c;
const Ecs = @import("libmine").Ecs;

pub const MouseButton = enum {
    left,
    right,
    middle,

    pub fn from_sdl(button: u8) MouseButton {
        switch (button) {
            1 => return .left,
            2 => return .middle,
            3 => return .right,
            else => {
                Log.log(.warn, "MouseButton value {d} unsupported...", .{button});
                return .left;
            },
        }
    }
};

pub const OnMouseMove = struct {
    data: *anyopaque,

    callback: *const fn (*anyopaque, move: Move) void,
    pub const Move = struct { dx: f32, dy: f32, x: f32, y: f32 };
};
pub const OnMouseClick = struct {
    data: *anyopaque,
    callback: *const fn (*anyopaque, button: MouseButton, x: f32, y: f32) void,
};
pub const OnMouseDown = struct {
    data: *anyopaque,
    callback: *const fn (*anyopaque, button: MouseButton, x: f32, y: f32) void,
};
pub const OnKeydown = struct {
    data: *anyopaque,
    callback: *const fn (data: *anyopaque, code: Scancode) void,
};

const MouseState = struct {
    left: bool,
    right: bool,
    middle: bool,
    x: f32,
    y: f32,

    const init: MouseState = std.mem.zeroes(MouseState);
};

pub const Scancode = struct {
    scancode: c.SDL_Scancode,

    pub fn from_sdl(scancode: c.SDL_Scancode) Scancode {
        return .{ .scancode = scancode };
    }
};

this_frame_pressed_keys: std.AutoHashMapUnmanaged(Scancode, void),
prev_frame_pressed_keys: std.AutoHashMapUnmanaged(Scancode, void),
this_frame_mouse_state: MouseState,
prev_frame_mouse_state: MouseState,

pre_system: Ecs.SystemRef,
post_system: Ecs.SystemRef,
keys_eid: Ecs.EntityRef,
keys_tag: Ecs.ComponentRef,
keydown_components: std.AutoHashMapUnmanaged(Scancode, KeydownEcs),
mouse_move_component: Ecs.ComponentRef,
mouse_move_system: Ecs.SystemRef,

const KeydownEcs = struct {
    component: Ecs.ComponentRef,
    system: Ecs.SystemRef,
};

const Keys = @This();
pub fn init(self: *Keys) !void {
    self.* = .{
        .prev_frame_pressed_keys = .empty,
        .this_frame_pressed_keys = .empty,
        .keydown_components = .empty,
        .prev_frame_mouse_state = .init,
        .this_frame_mouse_state = .init,
        .pre_system = 0,
        .post_system = 0,
        .keys_tag = 0,
        .keys_eid = 0,
        .mouse_move_component = 0,
        .mouse_move_system = 0,
    };
    self.keys_eid = try App.game_state().ecs.spawn();
    self.keys_tag = try App.game_state().ecs.register_component("main.keys.tag", void, true);
    self.mouse_move_component = try App.ecs().register_component("main.keys.mouse_move", OnMouseMove, true);

    try App.game_state().ecs.add_component(self.keys_eid, void, self.keys_tag, {});

    self.pre_system = try App.game_state().ecs.register_system(
        *Keys,
        "main.keys.pre",
        &.{self.keys_tag},
        self,
        Keys.manage_systems,
    );
    self.post_system = try App.game_state().ecs.register_system(
        *Keys,
        "main.keys.post",
        &.{self.keys_tag},
        self,
        struct {
            fn dummy(_: *Keys, _: *Ecs, _: Ecs.EntityRef) void {}
        }.dummy,
    );
    try App.game_state().ecs.ensure_eval_order(self.pre_system, self.post_system);

    self.mouse_move_system = try App.ecs().register_system(
        *Keys,
        "main.keys.mouse_move",
        &.{self.mouse_move_component},
        self,
        &struct {
            fn callback(keys: *Keys, ecs: *Ecs, eid: Ecs.EntityRef) void {
                const body = ecs.get_component(eid, OnMouseMove, keys.mouse_move_component).?;
                const x = keys.this_frame_mouse_state.x;
                const y = keys.this_frame_mouse_state.y;
                const dx = x - keys.prev_frame_mouse_state.x;
                const dy = y - keys.prev_frame_mouse_state.y;
                body.callback(body.data, .{ .x = x, .y = y, .dx = dx, .dy = dy });
            }
        }.callback,
    );
}

pub fn on_keydown(self: *Keys, key: Scancode) !void {
    try self.this_frame_pressed_keys.put(App.gpa(), key, {});
}

pub fn on_keyup(self: *Keys, key: Scancode) !void {
    _ = self.this_frame_pressed_keys.remove(key);
}

pub fn on_mouse_down(self: *Keys, button: MouseButton) void {
    switch (button) {
        inline else => |field| @field(self.this_frame_mouse_state, @tagName(field)) = true,
    }
}
pub fn on_mouse_up(self: *Keys, button: MouseButton) void {
    switch (button) {
        inline else => |field| @field(self.this_frame_mouse_state, @tagName(field)) = false,
    }
}
pub fn on_mouse_motion(self: *Keys, x: f32, y: f32) void {
    self.this_frame_mouse_state.x = x;
    self.this_frame_mouse_state.y = y;
}

pub fn is_key_down(self: *Keys, key: Scancode) bool {
    return self.this_frame_pressed_keys.contains(key);
}
pub fn is_key_just_pressed(self: *Keys, key: Scancode) bool {
    return self.this_frame_pressed_keys.contains(key) and !self.prev_frame_pressed_keys.contains(key);
}
pub fn is_key_just_released(self: *Keys, key: Scancode) bool {
    return !self.this_frame_pressed_keys.contains(key) and self.prev_frame_pressed_keys.contains(key);
}
pub fn is_mouse_down(self: *Keys, button: MouseButton) bool {
    switch (button) {
        inline else => |tag| return @field(self.this_frame_mouse_state, @tagName(tag)),
    }
}
pub fn mouse_pos(self: *Keys) struct { x: f32, y: f32 } {
    return .{ self.this_frame_mouse_state.x, self.this_frame_mouse_state.y };
}

fn manage_systems(self: *Keys, _: *Ecs, _: Ecs.EntityRef) void {
    var prev_frame = self.prev_frame_pressed_keys.keyIterator();
    while (prev_frame.next()) |entry| {
        const ecs_data = self.keydown_components.get(entry.*) orelse continue;
        App.game_state().ecs.disable_system(ecs_data.system);
    }

    var this_frame = self.this_frame_pressed_keys.keyIterator();
    while (this_frame.next()) |entry| {
        const ecs_data = self.keydown_components.get(entry.*) orelse continue;
        App.game_state().ecs.enable_system(ecs_data.system);
    }

    if (self.prev_frame_mouse_state.x != self.this_frame_mouse_state.x or
        self.prev_frame_mouse_state.y != self.this_frame_mouse_state.y)
    {
        App.ecs().enable_system(self.mouse_move_system);
    } else {
        App.ecs().disable_system(self.mouse_move_system);
    }
}

pub fn on_frame_start(self: *Keys) !void {
    _ = self;
}

pub fn on_frame_end(self: *Keys) !void {
    self.prev_frame_pressed_keys.clearRetainingCapacity();
    var it = self.this_frame_pressed_keys.iterator();
    while (it.next()) |entry| {
        try self.prev_frame_pressed_keys.put(App.gpa(), entry.key_ptr.*, {});
    }

    self.prev_frame_mouse_state = self.this_frame_mouse_state;
}

pub fn get_keydown_component(self: *Keys, key: Scancode) !Ecs.ComponentRef {
    const entry = try self.keydown_components.getOrPut(App.gpa(), key);
    if (entry.found_existing) return entry.value_ptr.component;
    const name = try std.fmt.allocPrintSentinel(App.frame_alloc(), "main.keys.keydown.{d}", .{key.scancode}, 0);
    Log.log(.debug, "Registering new keydown component: {s}", .{name});

    const KeydownSystem = struct {
        component: Ecs.ComponentRef,
        key: Scancode,
    };
    const component = try App.game_state().ecs.register_component(name, OnKeydown, true);
    const system = try App.game_state().ecs.register_system(KeydownSystem, name, &.{component}, .{
        .component = component,
        .key = key,
    }, struct {
        fn system(k: KeydownSystem, ecs: *Ecs, eid: Ecs.EntityRef) void {
            const callback = ecs.get_component(eid, OnKeydown, k.component).?.*;
            callback.callback(callback.data, k.key);
        }
    }.system);
    App.game_state().ecs.disable_system(system);

    try App.game_state().ecs.ensure_eval_order(self.pre_system, system);
    try App.game_state().ecs.ensure_eval_order(system, self.post_system);

    entry.value_ptr.* = .{ .component = component, .system = system };

    return component;
}

pub fn deinit(self: *Keys) void {
    self.keydown_components.deinit(App.gpa());
    self.this_frame_pressed_keys.deinit(App.gpa());
    self.prev_frame_pressed_keys.deinit(App.gpa());
}
