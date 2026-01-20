const std = @import("std");
const c = @import("c.zig").c;
const Options = @import("Build").Options;

var log_buf = std.mem.zeroes([Options.log_memory]u8);
var node_buf = std.mem.zeroes([Options.log_lines * @sizeOf(LogLineNode) * 2]u8);

var instance: Log = .{};

alloc_raw: std.heap.FixedBufferAllocator = .init(&log_buf),
alloc: std.heap.ThreadSafeAllocator = undefined,
lines: std.DoublyLinkedList = .{},
line_pool_alloc: std.heap.FixedBufferAllocator = .init(&node_buf),
line_pool: LinePool = undefined,
const LinePool = std.heap.MemoryPoolExtra(LogLineNode, .{ .growable = false });

pub fn init() void {
    instance = .{};
    instance.alloc = .{ .child_allocator = instance.alloc_raw.allocator() };
    instance.line_pool = LinePool.initPreheated(
        instance.line_pool_alloc.allocator(),
        Options.log_lines,
    ) catch unreachable;
}

const Log = @This();
const LogLineNode = struct {
    line: [:0]const u8,
    link: std.DoublyLinkedList.Node,

    fn from_link(link: *std.DoublyLinkedList.Node) *LogLineNode {
        return @fieldParentPtr("link", link);
    }
};

pub fn on_imgui() void {
    var cur = instance.lines.first;
    while (cur) |node| {
        const line: *LogLineNode = .from_link(node);
        c.igText("%s", line.line.ptr);
        cur = node.next;
    }
    if (had_new_line) {
        c.igScrollToItem(0);
        had_new_line = false;
    }
}

fn pop_line() bool {
    const line = LogLineNode.from_link(instance.lines.popFirst() orelse return false);
    instance.alloc.allocator().free(line.line);
    instance.line_pool.destroy(line);
    return true;
}

var had_new_line = false;
fn print_to_buf(comptime fmt: []const u8, args: anytype) !void {
    while (true) {
        const res = std.fmt.allocPrintSentinel(instance.alloc.allocator(), fmt, args, 0);
        if (res) |str| {
            const node: *LogLineNode = instance.line_pool.create() catch blk: {
                _ = pop_line();
                break :blk instance.line_pool.create() catch unreachable;
            };
            node.link = .{};
            node.line = str;
            instance.lines.append(&node.link);
            had_new_line = true;
            return;
        } else |_| {
            if (!pop_line()) break;
        }
    }
}

pub fn log_fn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const builtin = @import("builtin");
    if (builtin.mode != .Debug and @intFromEnum(level) > @intFromEnum(std.log.Level.warn)) return;

    switch (scope) {
        .chunk_manager, .block_renderer, .gpu_alloc => {
            if (@intFromEnum(level) > @intFromEnum(std.log.Level.info)) {
                return;
            }
        },
        else => {},
    }

    const prefix = "[" ++ @tagName(level) ++ "] " ++ "[" ++ @tagName(scope) ++ "]: ";
    const format = prefix ++ fmt ++ "\n";
    print_to_buf(format, args) catch {};

    var buf = std.mem.zeroes([256]u8);
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();
    nosuspend stderr.print(format, args) catch unreachable;
}
