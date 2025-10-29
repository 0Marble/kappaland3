pub const Server = @import("Server.zig");
const std = @import("std");

test "All tests" {
    std.testing.refAllDeclsRecursive(@This());
}

pub fn main() void {}
