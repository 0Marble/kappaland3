const App = @import("App.zig");
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
                std.log.warn("MouseButton value {d} unsupported...", .{button});
                return .left;
            },
        }
    }
};

const MouseState = struct {
    left: bool,
    right: bool,
    middle: bool,
    x: f32,
    y: f32,

    const init: MouseState = std.mem.zeroes(MouseState);
};

pub const MouseMoveEvent = struct {
    dx: f32,
    dy: f32,
    px: f32,
    py: f32,
};

pub const MouseDownEvent = struct {
    button: MouseButton,
    px: f32,
    py: f32,
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
keydown: std.AutoHashMapUnmanaged(Scancode, Ecs.EventRef),
mouse_move: Ecs.EventRef,
mouse_down: Ecs.EventRef,

const Keys = @This();
pub fn init(self: *Keys) !void {
    self.* = .{
        .prev_frame_pressed_keys = .empty,
        .this_frame_pressed_keys = .empty,
        .prev_frame_mouse_state = .init,
        .this_frame_mouse_state = .init,
        .pre_system = 0,
        .post_system = 0,
        .keys_tag = 0,
        .keys_eid = 0,

        .keydown = .empty,
        .mouse_move = 0,
        .mouse_down = 0,
    };
    self.keys_eid = try App.game_state().ecs.spawn();
    self.keys_tag = try App.game_state().ecs.register_component("main.keys.tag", void, true);

    self.mouse_move = try App.ecs().register_event("main.keys.mouse_move", MouseMoveEvent);
    self.mouse_down = try App.ecs().register_event("main.keys.mouse_down", MouseDownEvent);

    try App.game_state().ecs.add_component(self.keys_eid, void, self.keys_tag, {});

    self.pre_system = try App.game_state().ecs.register_system(
        *Keys,
        "main.keys.pre",
        &.{self.keys_tag},
        self,
        struct {
            fn dummy(_: *Keys, _: *Ecs, _: Ecs.EntityRef) void {}
        }.dummy,
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
    try App.ecs().ensure_eval_order(self.pre_system, self.post_system);

    const mouse_move_sys = try App.ecs().get_event_system(self.mouse_down);
    const mouse_down_sys = try App.ecs().get_event_system(self.mouse_move);
    try App.ecs().ensure_eval_order(self.pre_system, mouse_move_sys);
    try App.ecs().ensure_eval_order(mouse_move_sys, self.post_system);
    try App.ecs().ensure_eval_order(self.pre_system, mouse_down_sys);
    try App.ecs().ensure_eval_order(mouse_down_sys, self.post_system);
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
    return .{ .x = self.this_frame_mouse_state.x, .y = self.this_frame_mouse_state.y };
}
pub fn is_mouse_just_down(self: *Keys, button: MouseButton) bool {
    switch (button) {
        inline else => |tag| {
            const cur = @field(self.this_frame_mouse_state, @tagName(tag));
            const prev = @field(self.prev_frame_mouse_state, @tagName(tag));
            return cur and !prev;
        },
    }
}

pub fn on_frame_start(self: *Keys) !void {
    const dx = self.this_frame_mouse_state.x - self.prev_frame_mouse_state.x;
    const dy = self.this_frame_mouse_state.y - self.prev_frame_mouse_state.y;
    if (dx != 0 or dy != 0) {
        try App.ecs().emit_event(MouseMoveEvent, self.mouse_move, MouseMoveEvent{
            .dx = dx,
            .dy = dy,
            .px = self.this_frame_mouse_state.x,
            .py = self.this_frame_mouse_state.y,
        });
    }

    inline for (comptime std.meta.fieldNames(MouseButton)) |button| {
        if (@field(self.this_frame_mouse_state, button)) {
            try App.ecs().emit_event(MouseDownEvent, self.mouse_down, MouseDownEvent{
                .button = @field(MouseButton, button),
                .px = self.this_frame_mouse_state.x,
                .py = self.this_frame_mouse_state.y,
            });
        }
    }

    var it = self.this_frame_pressed_keys.keyIterator();
    while (it.next()) |key| {
        const evt = self.keydown.get(key.*) orelse continue;
        try App.ecs().emit_event(Scancode, evt, key.*);
    }
}

pub fn on_frame_end(self: *Keys) !void {
    self.prev_frame_pressed_keys.clearRetainingCapacity();
    var it = self.this_frame_pressed_keys.iterator();
    while (it.next()) |entry| {
        try self.prev_frame_pressed_keys.put(App.gpa(), entry.key_ptr.*, {});
    }

    self.prev_frame_mouse_state = self.this_frame_mouse_state;
}

pub fn get_keydown_event(self: *Keys, scancode: Scancode) !Ecs.EventRef {
    const entry = try self.keydown.getOrPut(App.gpa(), scancode);
    if (entry.found_existing) {
        return entry.value_ptr.*;
    }

    const name = try std.fmt.allocPrint(App.frame_alloc(), "main.keys.keydown.{}", .{scancode});
    const evt = try App.ecs().register_event(name, Scancode);
    entry.value_ptr.* = evt;
    const sys = try App.ecs().get_event_system(evt);
    try App.ecs().ensure_eval_order(self.pre_system, sys);
    try App.ecs().ensure_eval_order(sys, self.post_system);

    return evt;
}

pub fn deinit(self: *Keys) void {
    self.keydown.deinit(App.gpa());
    self.this_frame_pressed_keys.deinit(App.gpa());
    self.prev_frame_pressed_keys.deinit(App.gpa());
}
