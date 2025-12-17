const std = @import("std");
pub const App = @import("App.zig");

pub const std_options: std.Options = .{
    .logFn = App.log_fn,
};

pub fn main() !void {
    try App.init();
    defer App.deinit();

    try App.run();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
