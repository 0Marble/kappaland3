const App = @import("App.zig");
const std = @import("std");
const c = @import("c.zig").c;
const EventManager = @import("libmine").EventManager;

this_frame_pressed_keys: std.AutoHashMapUnmanaged(Scancode, void),
prev_frame_pressed_keys: std.AutoHashMapUnmanaged(Scancode, void),
this_frame_mouse_state: MouseState,
prev_frame_mouse_state: MouseState,

actions: std.StringHashMapUnmanaged(*ActionData),
actions_pool: std.heap.MemoryPool(ActionData),
key_pressed_actions: std.AutoHashMapUnmanaged(Scancode, std.DoublyLinkedList),
mouse_pressed_actions: std.EnumMap(MouseButton, std.DoublyLinkedList),
mouse_move_actions: std.DoublyLinkedList,

const Keys = @This();
pub fn init(self: *Keys) !void {
    self.* = .{
        .prev_frame_pressed_keys = .empty,
        .this_frame_pressed_keys = .empty,
        .prev_frame_mouse_state = .init,
        .this_frame_mouse_state = .init,

        .actions = .empty,
        .actions_pool = .init(App.gpa()),
        .mouse_pressed_actions = .initFull(.{}),
        .key_pressed_actions = .empty,
        .mouse_move_actions = .{},
    };
}

pub fn deinit(self: *Keys) void {
    self.this_frame_pressed_keys.deinit(App.gpa());
    self.prev_frame_pressed_keys.deinit(App.gpa());

    self.actions_pool.deinit();
    self.actions.deinit(App.gpa());
    self.key_pressed_actions.deinit(App.gpa());
}

pub fn emit_keydown(self: *Keys, key: Scancode) !void {
    try self.this_frame_pressed_keys.put(App.gpa(), key, {});
}

pub fn emit_keyup(self: *Keys, key: Scancode) !void {
    _ = self.this_frame_pressed_keys.remove(key);
}

pub fn emit_mouse_down(self: *Keys, button: MouseButton) void {
    switch (button) {
        inline else => |field| @field(self.this_frame_mouse_state, @tagName(field)) = true,
    }
}
pub fn emit_mouse_up(self: *Keys, button: MouseButton) void {
    switch (button) {
        inline else => |field| @field(self.this_frame_mouse_state, @tagName(field)) = false,
    }
}
pub fn emit_mouse_motion(self: *Keys, x: f32, y: f32) void {
    self.this_frame_mouse_state.x = x;
    self.this_frame_mouse_state.y = y;
}

pub fn is_key_pressed(self: *Keys, key: Scancode) bool {
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
pub fn mouse_pos(self: *Keys) MouseMove {
    return .{
        .px = self.this_frame_mouse_state.x,
        .py = self.this_frame_mouse_state.y,
        .dx = self.this_frame_mouse_state.x - self.prev_frame_mouse_state.x,
        .dy = self.this_frame_mouse_state.y - self.prev_frame_mouse_state.y,
    };
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
        var it = self.mouse_move_actions.first;
        while (it) |link| : (it = link.next) {
            const action = ActionData.from_link(link);
            try App.event_manager().emit(action.event, action.name);
        }
    }

    inline for (comptime std.meta.tags(MouseButton)) |button| {
        if (@field(self.this_frame_mouse_state, @tagName(button))) {
            const list = self.mouse_pressed_actions.get(button).?;
            var it = list.first;
            while (it) |link| : (it = link.next) {
                const action = ActionData.from_link(link);
                try App.event_manager().emit(action.event, action.name);
            }
        }
    }

    var keys = self.this_frame_pressed_keys.keyIterator();
    while (keys.next()) |key| {
        const list = self.key_pressed_actions.get(key.*) orelse continue;
        var it = list.first;
        while (it) |link| : (it = link.next) {
            const action = ActionData.from_link(link);
            try App.event_manager().emit(action.event, action.name);
        }
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

pub fn register_action(self: *Keys, name: []const u8) !void {
    const entry = try self.actions.getOrPut(App.gpa(), name);
    if (entry.found_existing) return error.ActionAlreadyExists;
    const action: *ActionData = try self.actions_pool.create();
    action.* = .{
        .name = name,
        .event = try App.event_manager().register_event([]const u8),
    };
    entry.value_ptr.* = action;
}

pub fn on_action(self: *Keys, name: []const u8, comptime func: anytype, args: anytype) !void {
    const action = self.actions.get(name) orelse return error.NoSuchAction;
    _ = try App.event_manager().add_listener(action.event, func, args);
}

pub fn bind_action(self: *Keys, name: []const u8, bind: Bind) !void {
    const action = self.actions.get(name) orelse return error.NoSuchAction;
    if (action.is_bound) {
        self.unbind_action_impl(action);
    }

    action.bound_to = .{ .link = .{}, .bind = bind };
    action.is_bound = true;
    switch (bind) {
        .scancode => |x| {
            const entry = try self.key_pressed_actions.getOrPutValue(App.gpa(), x, .{});
            entry.value_ptr.append(&action.bound_to.link);
        },
        .button => |x| {
            const list = self.mouse_pressed_actions.getPtrAssertContains(x);
            list.append(&action.bound_to.link);
        },
        .mouse_move => {
            self.mouse_move_actions.append(&action.bound_to.link);
        },
    }
}

pub fn get_action_bind(self: *Keys, name: []const u8) ?Bind {
    const action = self.actions.get(name) orelse return null;
    if (!action.is_bound) return null;
    return action.bound_to.bind;
}

pub fn unbind_action(self: *Keys, name: []const u8) !void {
    const action = self.actions.get(name) orelse return error.NoSuchAction;
    if (action.is_bound) {
        self.unbind_action_impl(action);
    }
}

fn unbind_action_impl(self: *Keys, action: *ActionData) void {
    std.debug.assert(action.is_bound);
    const link = &action.bound_to.link;
    switch (action.bound_to.bind) {
        .scancode => |x| {
            const list = self.key_pressed_actions.getPtr(x).?;
            list.remove(link);
        },
        .button => |x| {
            const list = self.mouse_pressed_actions.getPtrAssertContains(x);
            list.remove(link);
        },
        .mouse_move => {
            self.mouse_move_actions.remove(link);
        },
    }
    action.is_bound = false;
    @memset(std.mem.asBytes(&action.bound_to), 0x69);
}

const ActionData = struct {
    name: []const u8,
    bound_to: BoundTo = undefined,
    is_bound: bool = false,
    event: EventManager.Event,

    const BoundTo = struct { bind: Bind, link: std.DoublyLinkedList.Node };

    fn from_link(link: *std.DoublyLinkedList.Node) *ActionData {
        const bound_to: *BoundTo = @fieldParentPtr("link", link);
        const action: *ActionData = @fieldParentPtr("bound_to", bound_to);
        std.debug.assert(action.is_bound);
        return action;
    }
};

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

pub const Scancode = struct {
    scancode: c.SDL_Scancode,

    pub fn from_sdl(scancode: c.SDL_Scancode) Scancode {
        return .{ .scancode = scancode };
    }
};

const ScancodeOrMouseButton = union(enum) {
    scancode: Scancode,
    mouse_button: MouseButton,
};

pub const Bind = union(enum) {
    scancode: Scancode,
    button: MouseButton,
    mouse_move: void,
};

pub const MouseMove = struct {
    px: f32,
    py: f32,
    dx: f32,
    dy: f32,
};
