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

        var controller_tag: Ecs.ComponentRef = 0;

        pub const CommandBind = union(enum) {
            keydown: Keydown,
            mouse_move: MouseMove,

            const Keydown = *const fn (ctx: *Ctx, cmd: Command) void;
            const MouseMove = *const fn (ctx: *Ctx, cmd: Command, move: Keys.OnMouseMove.Move) void;
        };

        const Self = @This();
        pub fn init(self: *Self, ctx: *Ctx) !void {
            self.* = .{
                .ctx = ctx,
                .eid = try App.ecs().spawn(),
                .cmd_binds = .empty,
                .keydown_binds = .empty,
                .mousemove_binds = .empty,
            };
            if (controller_tag == 0) {
                controller_tag = try App.ecs().register_component("main.controller.tag", void, true);
            }
            try App.ecs().add_component(self.eid, void, controller_tag, {});

            try App.ecs().add_component(self.eid, Keys.OnMouseMove, App.key_state().mouse_move_component, .{
                .data = @ptrCast(self),
                .callback = @ptrCast(&on_mouse_move),
            });
        }

        fn on_keydown(self: *Self, code: Scancode) void {
            const cmds = self.keydown_binds.get(code).?;
            for (cmds.items) |cmd| {
                const bind = self.cmd_binds.get(cmd).?;
                if (bind == .keydown) bind.keydown(self.ctx, cmd);
            }
        }

        pub fn unbind_keydown(self: *Self, scancode: Scancode, cmd: Command) void {
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            const idx = std.mem.indexOfScalar(Command, entry.value_ptr.items, cmd) orelse return;
            Log.log(.debug, "{*}: unbind scancode {} from command {}", .{ self, scancode, cmd });

            _ = entry.value_ptr.swapRemove(idx);
            if (entry.value_ptr.items.len == 0) {
                try App.ecs().remove_component(self.eid, try App.key_state().get_keydown_component(scancode));
            }
        }

        pub fn bind_keydown(self: *Self, scancode: Scancode, cmd: Command) !void {
            Log.log(.debug, "{*}: bind scancode {} to command {}", .{ self, scancode, cmd });
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            try entry.value_ptr.append(App.gpa(), cmd);

            if (!entry.found_existing) {
                try App.ecs().add_component(
                    self.eid,
                    Keys.OnKeydown,
                    try App.key_state().get_keydown_component(scancode),
                    .{
                        .data = @ptrCast(self),
                        .callback = @ptrCast(&on_keydown),
                    },
                );
            }
        }

        pub fn bind_command(self: *Self, cmd: Command, bind: CommandBind) !void {
            _ = try self.cmd_binds.getOrPutValue(App.gpa(), cmd, bind);
            if (bind == .mouse_move) {
                try self.mousemove_binds.append(App.gpa(), cmd);
            }
        }

        fn on_mouse_move(self: *Self, move: Keys.OnMouseMove.Move) void {
            for (self.mousemove_binds.items) |cmd| {
                const callback = self.cmd_binds.get(cmd).?;
                if (callback == .mouse_move) callback.mouse_move(self.ctx, cmd, move);
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
        }
    };
}
