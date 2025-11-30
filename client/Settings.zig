const std = @import("std");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const Log = @import("libmine").Log;

file_name: []const u8,
settings: Map,
changed: std.StringHashMapUnmanaged(void),

const Map = std.StringArrayHashMapUnmanaged(Node);

const Settings = @This();
pub fn init() !Settings {
    const file = try std.fs.cwd().openFile(Options.settings_file, .{});
    defer file.close();

    const len = (try file.stat()).size;
    const source = try App.frame_alloc().allocSentinel(u8, len, 0);
    const read_amt = try file.read(@ptrCast(source));
    std.debug.assert(read_amt == len);

    return try Scanner.scan(Options.settings_file, source);
}

pub fn deinit(self: *Settings) void {
    _ = self;
}

pub fn on_imgui(self: *Settings) !void {
    try App.gui().add_to_frame(Settings, "Settings", self, on_imgui_impl, @src());
}

fn on_imgui_impl(self: *Settings) !void {
    self.changed = .empty;

    var it = self.settings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const val = entry.value_ptr;
        switch (val.*) {
            .checkbox => {
                if (c.igCheckbox(@as(c_str, @ptrCast(name)), &val.checkbox.value)) {
                    try self.changed.put(App.frame_alloc(), name, {});
                }
            },

            else => c.igText(
                "Invalid: %s",
                @as(c_str, @ptrCast(@tagName(std.meta.activeTag(val.*)))),
            ),
        }
    }
}

const Node = union(enum) {
    section: void,
    checkbox: struct { value: bool },
};

const Scanner = struct {
    const ZonIndex = std.zig.Zoir.Node.Index;

    zoir: std.zig.Zoir,
    ast: std.zig.Ast,
    source: [:0]const u8,
    stack: std.ArrayListUnmanaged(ZonIndex),
    file_name: []const u8,

    map: Map,

    const OOM = std.mem.Allocator.Error;

    pub fn scan(file_name: []const u8, source: [:0]const u8) OOM!Settings {
        const ast = try std.zig.Ast.parse(App.frame_alloc(), source, .zon);
        const zoir = try std.zig.ZonGen.generate(App.frame_alloc(), ast, .{});
        std.debug.assert(!zoir.hasCompileErrors());

        var scanner = Scanner{
            .zoir = zoir,
            .ast = ast,
            .source = source,
            .file_name = file_name,
            .stack = .empty,
            .map = .empty,
        };
        try scanner.scan_node(.root);

        return .{
            .file_name = file_name,
            .settings = scanner.map,
            .changed = .empty,
        };
    }

    fn scan_node(self: *Scanner, idx: ZonIndex) OOM!void {
        const kind_idx = self.get_child_ensure_type(idx, .enum_literal, "kind") orelse return;
        const kind = std.meta.stringToEnum(std.meta.Tag(Node), kind_idx.get(self.zoir).enum_literal.get(self.zoir)) orelse {
            self.report_error(kind_idx, "Invalid kind", .{});
            return;
        };

        switch (kind) {
            .section => try self.scan_section(idx),
            inline else => |tag| try self.scan_auto(tag, idx),
        }
    }

    fn scan_section(self: *Scanner, idx: ZonIndex) OOM!void {
        const children_idx = self.get_child_ensure_type(idx, .array_literal, "children") orelse return;
        const children = children_idx.get(self.zoir).array_literal;

        try self.stack.append(App.frame_alloc(), idx);

        for (0..children.len) |i| {
            try self.scan_node(children.at(@intCast(i)));
        }
    }

    fn scan_auto(self: *Scanner, comptime tag: std.meta.Tag(Node), idx: ZonIndex) OOM!void {
        const Body = @FieldType(Node, @tagName(tag));
        var diag = std.zon.parse.Diagnostics{};
        const parsed = std.zon.parse.fromZoirNode(
            Body,
            App.frame_alloc(),
            self.ast,
            self.zoir,
            idx,
            &diag,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            if (err == OOM.OutOfMemory) return OOM.OutOfMemory;
            self.report_error(idx, "Invalid node: {f}", .{diag});
            return;
        };

        const name = (try self.calc_current_name(idx)) orelse return;
        try self.map.put(App.static_alloc(), name, @unionInit(Node, @tagName(tag), parsed));
    }

    fn scan_checkbox(self: *Scanner, idx: ZonIndex) OOM!void {
        const value = self.get_child(idx, "value") orelse return;

        const val = switch (value.get(self.zoir)) {
            .true => true,
            .false => false,
            else => {
                self.report_error(idx, "Value should be a bool", .{});
                return;
            },
        };
        const name = (try self.calc_current_name(idx)) orelse {
            return;
        };

        try self.map.put(App.static_alloc(), name, Node{ .checkbox = val });
    }

    fn calc_current_name(self: *Scanner, last: ZonIndex) OOM!?[:0]const u8 {
        var acc = std.ArrayListUnmanaged(u8).empty;
        var writer = acc.writer(App.frame_alloc());

        for (self.stack.items) |idx| {
            const name_idx = self.get_child_ensure_type(idx, .string_literal, "name") orelse return null;
            const name = name_idx.get(self.zoir).string_literal;
            try writer.print(".{s}", .{name});
        }
        {
            const name_idx = self.get_child_ensure_type(last, .string_literal, "name") orelse return null;
            const name = name_idx.get(self.zoir).string_literal;
            try writer.print(".{s}", .{name});
        }

        return try acc.toOwnedSliceSentinel(App.static_alloc(), 0);
    }

    fn get_child(self: *Scanner, parent_idx: ZonIndex, name: []const u8) ?ZonIndex {
        const parent = parent_idx.get(self.zoir);
        if (parent != .struct_literal) {
            self.report_error(parent_idx, "Expected a struct_literal", .{});
            return null;
        }

        const child_idx: ZonIndex = loop: for (parent.struct_literal.names, 0..) |child, i| {
            if (std.mem.eql(u8, name, child.get(self.zoir))) {
                break :loop parent.struct_literal.vals.at(@intCast(i));
            }
        } else {
            self.report_error(parent_idx, "Missing field '{s}'", .{name});
            return null;
        };

        return child_idx;
    }

    fn get_child_ensure_type(
        self: *Scanner,
        parent_idx: ZonIndex,
        comptime typ: std.meta.Tag(std.zig.Zoir.Node),
        name: []const u8,
    ) ?ZonIndex {
        const child_idx = self.get_child(parent_idx, name) orelse return null;
        if (child_idx.get(self.zoir) != typ) {
            self.report_error(child_idx, "Expected a '{s}'", .{@tagName(typ)});
            return null;
        }
        return child_idx;
    }

    fn report_error(self: *Scanner, idx: ZonIndex, comptime msg: []const u8, args: anytype) void {
        Log.log(.warn, msg, args);
        const ast_node = idx.getAstNode(self.zoir);
        const toc = self.ast.nodeMainToken(ast_node);
        const loc = self.ast.tokenLocation(0, toc);

        Log.log(.warn, "\t at {s}:{d}:{d}", .{ self.file_name, loc.line, loc.column });
    }
};
