const std = @import("std");
pub const App = @import("App.zig");
pub const utils = @import("util.zig");
const gl = @import("gl");
const c = @import("c.zig").c;
pub const Log = @import("Log.zig");

pub fn main() !void {
    try App.init();
    defer App.deinit();

    try App.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
