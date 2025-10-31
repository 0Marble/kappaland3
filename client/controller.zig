const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const Log = @import("libmine").Log;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");
const std = @import("std");

pub fn Controller(comptime Ctx: type, comptime Command: type) type {
    return struct {
        ctx: *Ctx,
        eid: Ecs.EntityRef,
        cmd_binds: std.AutoArrayHashMapUnmanaged(Command, std.ArrayListUnmanaged(CommandBind)),
        keydown_binds: std.AutoArrayHashMapUnmanaged(c.SDL_Scancode, std.ArrayListUnmanaged(Command)),

        var controller_tag: Ecs.ComponentRef = 0;

        pub const CommandBind = union(enum) {
            keydown: Keydown,

            const Keydown = *const fn (ctx: *Ctx, cmd: Command) void;
        };

        const Self = @This();
        pub fn init(ctx: *Ctx) !Self {
            const self = Self{
                .ctx = ctx,
                .eid = try App.ecs().spawn(),
                .cmd_binds = .empty,
                .keydown_binds = .empty,
            };
            if (controller_tag == 0) {
                controller_tag = try App.ecs().register_component("main.controller.tag", void, true);
            }
            try App.ecs().add_component(self.eid, void, controller_tag, {});

            return self;
        }

        fn on_keydown(self: *Self, code: c.SDL_Scancode) void {
            const cmds = self.keydown_binds.get(code).?;
            for (cmds.items) |cmd| {
                const binds = self.cmd_binds.get(cmd).?;
                for (binds.items) |bind| {
                    if (bind == .keydown) bind.keydown(self.ctx, cmd);
                }
            }
        }

        pub fn unbind_keydown(self: *Self, scancode: c.SDL_Scancode, cmd: Command) void {
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            const idx = std.mem.indexOfScalar(Command, entry.value_ptr.items, cmd) orelse return;
            _ = entry.value_ptr.swapRemove(idx);
        }

        pub fn bind_keydown(self: *Self, scancode: c.SDL_Scancode, cmd: Command) !void {
            const entry = try self.keydown_binds.getOrPutValue(App.gpa(), scancode, .empty);
            try entry.value_ptr.append(App.gpa(), cmd);

            if (!entry.found_existing) {
                try App.ecs().add_component(
                    self.eid,
                    Keys.KeydownComponent,
                    try App.key_state().get_keydown_component(scancode),
                    .{
                        .data = @ptrCast(self),
                        .on_keydown = @ptrCast(on_keydown),
                    },
                );
            }
        }

        pub fn bind_command(self: *Self, cmd: Command, bind: CommandBind) !void {
            const entry = try self.cmd_binds.getOrPutValue(App.gpa(), cmd, .empty);
            try entry.value_ptr.append(App.gpa(), bind);
        }

        pub fn deinit(self: *Self) void {
            App.ecs().kill(self.eid);
        }
    };
}
