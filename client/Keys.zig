const App = @import("App.zig");
const Log = @import("libmine").Log;
const std = @import("std");
const c = @import("c.zig").c;
const Ecs = @import("libmine").Ecs;

this_frame_pressed_keys: std.AutoHashMapUnmanaged(c.SDL_Scancode, void),
prev_frame_pressed_keys: std.AutoHashMapUnmanaged(c.SDL_Scancode, void),

pre_system: Ecs.SystemRef,
post_system: Ecs.SystemRef,
keys_eid: Ecs.EntityRef,
keys_tag: Ecs.ComponentRef,

keydown_components: std.AutoHashMapUnmanaged(c.SDL_Scancode, KeydownEcs),
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
        .pre_system = 0,
        .post_system = 0,
        .keys_tag = 0,
        .keys_eid = 0,
    };
    self.keys_eid = try App.game_state().ecs.spawn();
    self.keys_tag = try App.game_state().ecs.register_component("main.keys.tag", void, true);
    try App.game_state().ecs.add_component(self.keys_eid, void, self.keys_tag, {});

    self.pre_system = try App.game_state().ecs.register_system(
        *Keys,
        "main.keys.pre",
        &.{self.keys_tag},
        self,
        Keys.manage_keys_systems,
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
}

pub fn on_keydown(self: *Keys, key: c.SDL_Scancode) !void {
    try self.this_frame_pressed_keys.put(App.gpa(), key, {});
}

pub fn on_keyup(self: *Keys, key: c.SDL_Scancode) !void {
    _ = self.this_frame_pressed_keys.remove(key);
}

fn manage_keys_systems(self: *Keys, _: *Ecs, _: Ecs.EntityRef) void {
    var prev_frame = self.prev_frame_pressed_keys.keyIterator();
    while (prev_frame.next()) |entry| {
        _ = self.get_keydown_component(entry.*) catch |err| {
            Log.log(.warn, "Keys@{*}: failed to get_keydown_component: {}", .{ self, err });
            continue;
        };
        const ecs_data = self.keydown_components.get(entry.*).?;
        App.game_state().ecs.disable_system(ecs_data.system);
    }

    var this_frame = self.this_frame_pressed_keys.keyIterator();
    while (this_frame.next()) |entry| {
        _ = self.get_keydown_component(entry.*) catch |err| {
            Log.log(.warn, "Keys@{*}: failed to get_keydown_component: {}", .{ self, err });
            continue;
        };
        const ecs_data = self.keydown_components.get(entry.*).?;
        App.game_state().ecs.enable_system(ecs_data.system);
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
}

pub const KeydownComponent = struct {
    data: *anyopaque,
    on_keydown: *const fn (data: *anyopaque, code: c.SDL_Scancode) void,
};
const KeydownSystem = struct {
    component: Ecs.ComponentRef,
    key: c.SDL_Scancode,
};
pub fn get_keydown_component(self: *Keys, key: c.SDL_Scancode) !Ecs.ComponentRef {
    const entry = try self.keydown_components.getOrPut(App.gpa(), key);
    if (entry.found_existing) return entry.value_ptr.component;
    const name = try std.fmt.allocPrintSentinel(App.frame_alloc(), "main.keys.keydown.{d}", .{key}, 0);
    Log.log(.debug, "Registering new keydown component: {s}", .{name});

    const component = try App.game_state().ecs.register_component(name, KeydownComponent, true);
    const system = try App.game_state().ecs.register_system(KeydownSystem, name, &.{component}, .{
        .component = component,
        .key = key,
    }, struct {
        fn system(k: KeydownSystem, ecs: *Ecs, eid: Ecs.EntityRef) void {
            const callback = ecs.get_component(eid, KeydownComponent, k.component).?.*;
            callback.on_keydown(callback.data, k.key);
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
