const std = @import("std");
pub const App = @import("App.zig");

pub fn main() !void {
    try App.init();
    defer App.deinit();

    try App.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
