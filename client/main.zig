const std = @import("std");
pub const App = @import("App.zig");
pub const Log = @import("Log.zig");

pub const std_options: std.Options = .{
    .logFn = Log.log_fn,
};

pub fn main() !void {
    Log.init();

    try App.init();
    defer App.deinit();

    try App.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
