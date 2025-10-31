const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const Log = @import("libmine").Log;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");
const std = @import("std");

eid: Ecs.EntityRef,
data: *anyopaque,
keybinds: std.AutoArrayHashMapUnmanaged(u32, Keybind),
reverse: std.AutoHashMapUnmanaged(c.SDL_Scancode, u32),

const Keybind = struct {
    scancode: c.SDL_Scancode,
    callbacks: std.ArrayListUnmanaged(Callback),
};

const Callback = *const fn (*anyopaque, u32) void;
const Controller = @This();

pub const init: Controller = .{
    .eid = 0,
    .data = undefined,
    .keybinds = .empty,
    .reverse = .empty,
};

pub fn attatch(self: *Controller, comptime Ctx: type, ctx: *Ctx) !void {
    const ecs = &App.game_state().ecs;
    self.* = .{
        .eid = try ecs.spawn(),
        .data = @ptrCast(ctx),
        .keybinds = .empty,
        .reverse = .empty,
    };
}

pub fn detatch(self: *Controller) void {
    const ecs = &App.game_state().ecs;
    ecs.kill(self.eid);
    self.eid = 0;
    for (self.keybinds.values()) |*kb| {
        kb.callbacks.clearAndFree(App.gpa());
    }
    self.keybinds.clearAndFree(App.gpa());
    self.reverse.clearAndFree(App.gpa());
}

fn check_control_type(comptime T: type) void {
    const ti = @typeInfo(T);
    if (ti != .@"enum" or ti.@"enum".tag_type != u32) @compileError("Control type should be an enum(u32)");
}

pub fn unbind(self: *Controller, comptime T: type, control: T) void {
    check_control_type(T);

    const bound: u32 = @intFromEnum(control);
    if (self.keybinds.fetchSwapRemove(bound)) |old| {
        Log.log(.debug, "Controller@{*}: unbind scancode {d} from key {d}", .{ self, old.value.scancode, old.key });
        _ = self.reverse.remove(old.value.scancode);
        old.value.callbacks.deinit(App.gpa());
    }
}

pub fn bind_key(self: *Controller, scancode: c.SDL_Scancode, comptime T: type, control: T) !void {
    check_control_type(T);

    const ecs = &App.game_state().ecs;
    const keys = App.key_state();
    const bound: u32 = @intFromEnum(control);
    if (try self.reverse.fetchPut(App.gpa(), scancode, bound)) |old| {
        Log.log(.debug, "Controller@{*}: unbind scancode {d} from key {d}", .{ self, scancode, old.value });
        var removed_bind = self.keybinds.fetchSwapRemove(old.value).?;
        removed_bind.value.callbacks.deinit(App.gpa());
    } else {
        try self.keybinds.put(App.gpa(), bound, .{
            .scancode = scancode,
            .callbacks = .empty,
        });

        try ecs.add_component(
            self.eid,
            Keys.KeydownComponent,
            try keys.get_keydown_component(scancode),
            .{
                .data = self,
                .on_keydown = @ptrCast(&struct {
                    fn on_keydown(controller: *Controller, code: c.SDL_Scancode) void {
                        const keybind = controller.reverse.get(code).?;
                        const callbacks = controller.keybinds.getPtr(keybind).?;
                        for (callbacks.callbacks.items) |cb| {
                            cb(controller.data, keybind);
                        }
                    }
                }.on_keydown),
            },
        );
    }
    Log.log(.debug, "Controller@{*}: bind scancode {d} to key {d}", .{ self, scancode, bound });
}

pub fn on_keydown(
    self: *Controller,
    comptime Ctx: type,
    comptime Control: type,
    key: Control,
    callback: *const fn (*Ctx, Control) void,
) !void {
    check_control_type(Control);

    const scancode = self.keybinds.getPtr(@intFromEnum(key)) orelse return error.UnboundKey;
    try scancode.callbacks.append(App.gpa(), @ptrCast(callback));
}
