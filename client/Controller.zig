const Ecs = @import("libmine").Ecs;
const App = @import("App.zig");
const Log = @import("libmine").Log;
const c = @import("c.zig").c;
const Keys = @import("Keys.zig");

eid: Ecs.EntityRef,
data: *anyopaque,

const Controller = @This();

pub const init: Controller = .{ .eid = 0, .data = undefined };

pub fn attatch(self: *Controller, comptime Ctx: type, ctx: *Ctx) !void {
    const ecs = &App.game_state().ecs;
    self.* = .{
        .eid = try ecs.spawn(),
        .data = @ptrCast(ctx),
    };
}

pub fn detatch(self: *Controller) void {
    const ecs = &App.game_state().ecs;
    ecs.kill(self.eid);
    self.eid = 0;
}

pub fn bind_keydown(
    self: *Controller,
    comptime Ctx: type,
    key: c.SDL_Scancode,
    callback: *const fn (*Ctx, c.SDL_Scancode) void,
) !void {
    const ecs = &App.game_state().ecs;
    const keys = App.key_state();
    try ecs.add_component(self.eid, Keys.KeydownComponent, try keys.get_keydown_component(key), .{
        .data = self.data,
        .on_keydown = @ptrCast(callback),
    });
}
