const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const Log = @import("libmine").Log;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");
const std = @import("std");
const Scancode = Keys.Scancode;

pub fn Controller(comptime Ctx: type, comptime Command: type) type {
    return struct {
        ctx: *Ctx,
        eid: Ecs.EntityRef,
        cmd_binds: std.AutoHashMapUnmanaged(Command, CommandBind),

        keydown_binds: std.AutoArrayHashMapUnmanaged(Scancode, std.ArrayListUnmanaged(Command)),
        mousemove_binds: std.ArrayListUnmanaged(Command),
        mousedown_binds: std.ArrayListUnmanaged(Command),

        var controller_tag: Ecs.ComponentRef = 0;

        pub const CommandBind = union(enum) {
            normal: Normal,
            mouse_move: MouseMove,
            mouse_down: MouseDown,

            const Normal = *const fn (ctx: *Ctx, cmd: Command) void;
            const MouseMove = *const fn (ctx: *Ctx, cmd: Command, move: Keys.MouseMoveEvent) void;
            const MouseDown = *const fn (ctx: *Ctx, cmd: Command, down: Keys.MouseDownEvent) void;
        };

        const Self = @This();
        pub fn init(self: *Self, ctx: *Ctx) !void {
            self.* = .{
                .ctx = ctx,
                .eid = try App.ecs().spawn(),
                .cmd_binds = .empty,
                .keydown_binds = .empty,
                .mousemove_binds = .empty,
                .mousedown_binds = .empty,
            };
            if (controller_tag == 0) {
                controller_tag = try App.ecs().register_component("main.controller.tag", void, true);
            }
            try App.ecs().add_component(self.eid, void, controller_tag, {});

            try App.ecs().add_event_listener(
                self.eid,
                Keys.MouseMoveEvent,
                *Self,
                App.key_state().mouse_move,
                self,
                &on_mouse_move_handler,
            );
            try App.ecs().add_event_listener(
                self.eid,
                Keys.MouseDownEvent,
                *Self,
                App.key_state().mouse_down,
                self,
                &on_mouse_down_handler,
            );
        }

        pub fn bind_command(self: *Self, cmd: Command, bind: CommandBind) !void {
            _ = try self.cmd_binds.getOrPutValue(App.gpa(), cmd, bind);
            switch (bind) {
                .mouse_down => {
                    try self.mousedown_binds.append(App.gpa(), cmd);
                },
                .mouse_move => {
                    try self.mousemove_binds.append(App.gpa(), cmd);
                },
                .normal => {},
            }
        }

        pub fn bind_keydown(self: *Self, scancode: Scancode, cmd: Command) !void {
            Log.log(.debug, "{*}: bind scancode {} to command {}", .{ self, scancode, cmd });
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            try entry.value_ptr.append(App.gpa(), cmd);

            if (!entry.found_existing) {
                const evt = try App.key_state().get_keydown_event(scancode);
                try App.ecs().add_event_listener(self.eid, Keys.Scancode, *Self, evt, self, on_keydown_handler);
            }
        }

        pub fn unbind_keydown(self: *Self, scancode: Scancode, cmd: Command) void {
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            const idx = std.mem.indexOfScalar(Command, entry.value_ptr.items, cmd) orelse return;
            Log.log(.debug, "{*}: unbind scancode {} from command {}", .{ self, scancode, cmd });

            _ = entry.value_ptr.swapRemove(idx);
            if (entry.value_ptr.items.len == 0) {
                try App.ecs().remove_event_listener(self.eid, try App.key_state().get_keydown_event(scancode));
            }
        }

        pub fn deinit(self: *Self) void {
            App.ecs().kill(self.eid);
            for (self.keydown_binds.values()) |*arr| {
                arr.deinit(App.gpa());
            }
            self.cmd_binds.deinit(App.gpa());
            self.keydown_binds.deinit(App.gpa());
            self.mousemove_binds.deinit(App.gpa());
            self.mousedown_binds.deinit(App.gpa());
        }

        fn on_keydown_handler(self: *Self, code: *Scancode) void {
            const cmds = self.keydown_binds.get(code.*).?;
            for (cmds.items) |cmd| {
                const bind = self.cmd_binds.get(cmd).?;
                if (bind == .normal) bind.normal(self.ctx, cmd);
            }
        }

        fn on_mouse_move_handler(self: *Self, move: *Keys.MouseMoveEvent) void {
            for (self.mousemove_binds.items) |cmd| {
                const callback = self.cmd_binds.get(cmd).?;
                switch (callback) {
                    .mouse_move => callback.mouse_move(self.ctx, cmd, move.*),
                    .normal => callback.normal(self.ctx, cmd),
                    else => {},
                }
            }
        }

        fn on_mouse_down_handler(self: *Self, down: *Keys.MouseDownEvent) void {
            for (self.mousedown_binds.items) |cmd| {
                const callback = self.cmd_binds.get(cmd).?;
                switch (callback) {
                    .mouse_down => callback.mouse_down(self.ctx, cmd, down.*),
                    .normal => callback.normal(self.ctx, cmd),
                    else => {},
                }
            }
        }
    };
}
