const std = @import("std");
pub const App = @import("App.zig");
pub const utils = @import("util.zig");
const gl = @import("gl");
const c = @import("c.zig").c;
const libmine = @import("libmine");
const Log = libmine.Log;

const Options = @import("ClientOptions");

pub fn main() !void {
    Log.log(.debug, "Client compiled with the following options:", .{});
    inline for (comptime std.meta.declarations(Options)) |decl| {
        Log.log(.debug, "\t{s}: {}", .{ decl.name, @field(Options, decl.name) });
    }

    try App.init();
    defer App.deinit();

    try App.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
