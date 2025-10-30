const std = @import("std");

arena: std.heap.ArenaAllocator,
map: std.StringHashMapUnmanaged(void),

const Self = @This();
pub fn init(gpa: std.mem.Allocator) Self {
    return .{ .arena = .init(gpa), .map = .empty };
}

pub fn ensure_stored(self: *Self, gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (self.map.getEntry(s)) |old| {
        return old.key_ptr.*;
    } else {
        const duped = try self.arena.allocator().dupe(u8, s);
        try self.map.put(gpa, duped, {});
        return duped;
    }
}

pub fn contains(self: *Self, s: []const u8) bool {
    return self.map.contains(s);
}

pub fn clear(self: *Self) void {
    self.map.clearRetainingCapacity();
    _ = self.arena.reset(.{ .retain_capacity = {} });
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.arena.deinit();
    self.map.deinit(gpa);
}
