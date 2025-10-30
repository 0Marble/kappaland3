const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        push_buf: std.ArrayListUnmanaged(T),
        pop_buf: std.ArrayListUnmanaged(T),
        pop_offset: usize,

        const Self = @This();
        pub const empty: Self = .{
            .pop_buf = .empty,
            .push_buf = .empty,
            .pop_offset = 0,
        };

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.push_buf.deinit(gpa);
            self.pop_buf.deinit(gpa);
        }

        pub fn push(self: *Self, gpa: std.mem.Allocator, x: T) std.mem.Allocator.Error!void {
            try self.push_buf.append(gpa, x);
        }

        pub fn pop(self: *Self) ?T {
            if (self.pop_offset == self.pop_buf.items.len) {
                if (self.push_buf.items.len == 0) {
                    return null;
                }
                self.pop_offset = 0;
                std.mem.swap(@TypeOf(self.pop_buf), &self.pop_buf, &self.push_buf);
                self.push_buf.clearRetainingCapacity();
            }
            self.pop_offset += 1;
            return self.pop_buf.items[self.pop_offset - 1];
        }

        pub fn peek(self: *Self) ?T {
            if (self.pop_offset == self.pop_buf.items.len) {
                if (self.push_buf.items.len == 0) {
                    return null;
                }
                return self.push_buf.items[0];
            }
            return self.pop_buf.items[self.pop_offset];
        }

        pub fn clear(self: *Self) void {
            self.pop_offset = 0;
            self.push_buf.clearRetainingCapacity();
            self.pop_buf.clearRetainingCapacity();
        }
    };
}

test "ops" {
    const iter_cnt = 10000;
    var golden = std.ArrayListUnmanaged(u32).empty;
    defer golden.deinit(std.testing.allocator);
    var queue = Queue(u32).empty;
    defer queue.deinit(std.testing.allocator);

    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const rng = prng.random();

    for (0..iter_cnt) |_| {
        const Action = enum { push, pop, peek };

        const action: Action = @enumFromInt(rng.intRangeAtMost(u32, 0, 2));
        switch (action) {
            .push => {
                const x = rng.int(u32);
                try golden.append(std.testing.allocator, x);
                try queue.push(std.testing.allocator, x);
            },
            .pop => {
                const y: ?u32 = if (golden.items.len == 0) null else golden.orderedRemove(0);
                try std.testing.expectEqual(y, queue.pop());
            },
            .peek => {
                const y: ?u32 = if (golden.items.len == 0) null else golden.items[0];
                try std.testing.expectEqual(y, queue.peek());
            },
        }
    }
}
