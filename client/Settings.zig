const std = @import("std");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;

settings: Map,
events: std.StringHashMapUnmanaged(Ecs.EventRef),

const Map = std.StringArrayHashMapUnmanaged(Node);

const Settings = @This();
pub fn init() !Settings {
    var self: Settings = .{
        .events = .empty,
        .settings = .empty,
    };
    try self.load_template();

    return self;
}

fn load_template(self: *Settings) !void {
    const Visitor = struct {
        const OOM = std.mem.Allocator.Error;
        fn add_node_callback(this: *Settings, name: [:0]const u8, node: Node) OOM!void {
            try this.settings.put(App.static_alloc(), name, node);
        }
    };
    try Scanner(*Settings, Visitor.OOM).scan(self, &Visitor.add_node_callback);
}

pub fn deinit(self: *Settings) void {
    self.save() catch |err| {
        Log.log(.warn, "Couldn't save settings: {}", .{err});
    };
}

pub fn save(self: *Settings) !void {
    const Visitor = struct {
        const Error = std.zon.Serializer.Error;

        settings: *Settings,
        struct_builder: *std.zon.Serializer.Struct,

        const Visitor = @This();
        fn save_node_callback(this: *Visitor, name: [:0]const u8, node: Node) Error!void {
            switch (std.meta.activeTag(node)) {
                .section => unreachable,
                inline else => |tag| {
                    const Value = @FieldType(@FieldType(Node, @tagName(tag)), "value");
                    const default = @field(node, @tagName(tag)).value;
                    const value = this.settings.get_value(Value, name) orelse default;
                    try this.struct_builder.field(name, value, .{});
                },
            }
        }
    };

    var file = try std.fs.cwd().createFile(Options.settings_file, .{});
    defer file.close();

    var buf = std.mem.zeroes([256]u8);
    var writer = file.writer(&buf);
    var serializer = std.zon.Serializer{ .writer = &writer.interface };
    var struct_builder = try serializer.beginStruct(.{});

    var visitor = Visitor{
        .settings = self,
        .struct_builder = &struct_builder,
    };
    try Scanner(*Visitor, Visitor.Error).scan(&visitor, Visitor.save_node_callback);

    try struct_builder.end();
    try writer.interface.flush();
}

pub fn settings_change_event(self: *Settings, comptime Body: type, name: []const u8) !Ecs.EventRef {
    const node: ?Node = if (self.settings.get(name)) |n| blk: {
        switch (std.meta.activeTag(n)) {
            .section => {},
            inline else => |tag| {
                const Value = @FieldType(@FieldType(Node, @tagName(tag)), "value");
                if (Value != Body) {
                    Log.log(.warn, "Type mismatch for setting '{s}', expected {s} got {s}", .{
                        name,
                        @typeName(Value),
                        @typeName(Body),
                    });
                    break :blk null;
                }
            },
        }
        break :blk n;
    } else blk: {
        Log.log(.warn, "Listening for non-existant settings '{s}'", .{name});
        break :blk null;
    };

    const entry = try self.events.getOrPut(App.static_alloc(), name);
    if (entry.found_existing) return entry.value_ptr.*;

    const evt = try App.ecs().register_event(null, Body);
    entry.value_ptr.* = evt;

    if (node) |n| {
        switch (std.meta.activeTag(n)) {
            .section => {},
            inline else => |tag| {
                if (Body == @FieldType(@FieldType(Node, @tagName(tag)), "value")) {
                    try App.ecs().emit_event(Body, evt, @field(@field(n, @tagName(tag)), "value"));
                }
            },
        }
    }

    return evt;
}

pub fn get_value(self: *Settings, comptime T: type, name: []const u8) ?T {
    const node = self.settings.get(name) orelse {
        Log.log(.warn, "Attempted to access non-existant setting: {s}", .{name});
        return null;
    };
    switch (std.meta.activeTag(node)) {
        .section => unreachable,
        inline else => |tag| {
            const Body = @FieldType(Node, @tagName(tag));
            const Value = @FieldType(Body, "value");
            if (Value != T) {
                Log.log(.warn, "Setting '{s}' type mismatch, expected {s} got {s}", .{
                    name,
                    @typeName(Value),
                    @typeName(T),
                });
                return null;
            }

            return @field(@field(node, @tagName(tag)), "value");
        },
    }
}

pub fn on_imgui(self: *Settings) !void {
    try App.gui().add_to_frame(Settings, "Settings", self, on_imgui_impl, @src());
}

fn emit_on_changed(self: *Settings, name: []const u8, node: *const Node) void {
    switch (std.meta.activeTag(node.*)) {
        .section => {},
        inline else => |tag| {
            const evt = self.events.get(name) orelse return;
            const Body = @FieldType(Node, @tagName(tag));
            const Value = @FieldType(Body, "value");
            App.ecs().emit_event(Value, evt, @field(@field(node, @tagName(tag)), "value")) catch |err| {
                Log.log(.warn, "Settings.emit_on_changed: {s}: Ecs.emit_event: {}", .{ name, err });
            };
        },
    }
}

fn on_imgui_impl(self: *Settings) !void {
    if (c.igButton("Save", .{})) {
        self.save() catch |err| {
            Log.log(.warn, "Couldn't save settings: {}", .{err});
        };
    }

    var it = self.settings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const c_name: c_str = @ptrCast(name);
        const val = entry.value_ptr;
        switch (val.*) {
            .checkbox => {
                if (c.igCheckbox(c_name, &val.checkbox.value)) {
                    self.emit_on_changed(name, val);
                }
            },
            .int_slider => {
                if (c.igSliderInt(
                    c_name,
                    &val.int_slider.value,
                    val.int_slider.min,
                    val.int_slider.max,
                    "%d",
                    0,
                )) {
                    self.emit_on_changed(name, val);
                }
            },
            .float_slider => {
                if (c.igSliderFloat(
                    c_name,
                    &val.float_slider.value,
                    val.float_slider.min,
                    val.float_slider.max,
                    "%.2f",
                    0,
                )) {
                    self.emit_on_changed(name, val);
                }
            },

            else => c.igText(
                "%s: todo %s",
                c_name,
                @as(c_str, @ptrCast(@tagName(std.meta.activeTag(val.*)))),
            ),
        }
    }
}

const Node = union(enum) {
    section: void,
    checkbox: struct { value: bool },
    int_slider: struct { min: i32, max: i32, value: i32 },
    float_slider: struct { min: f32, max: f32, value: f32 },
};

const Menu = @import("SettingsMenu");
fn Scanner(comptime Ctx: type, comptime Err: type) type {
    return struct {
        const VisitorCallback = fn (ctx: Ctx, name: [:0]const u8, node: Node) Err!void;
        const ScannerT = @This();

        ctx: Ctx,
        fptr: *const VisitorCallback,

        pub fn scan(ctx: Ctx, callback: *const VisitorCallback) Err!void {
            var self: ScannerT = .{
                .ctx = ctx,
                .fptr = callback,
            };
            try self.scan_node(Menu, &(.{}));
        }

        fn scan_node(
            self: ScannerT,
            node: anytype,
            comptime name_stack: []const []const u8,
        ) Err!void {
            const kind: std.meta.Tag(Node) = node.kind;
            switch (kind) {
                .section => try self.scan_section(node, name_stack),
                inline else => |tag| try self.scan_any(node, tag, name_stack),
            }
        }

        fn scan_section(
            self: ScannerT,
            node: anytype,
            comptime name_stack: []const []const u8,
        ) Err!void {
            const new_stack = name_stack ++ .{node.name};

            inline for (node.children) |child| {
                try self.scan_node(child, new_stack);
            }
        }

        fn scan_any(
            self: ScannerT,
            node: anytype,
            comptime tag: std.meta.Tag(Node),
            comptime name_stack: []const []const u8,
        ) Err!void {
            const Sub = @FieldType(Node, @tagName(tag));
            var sub: Sub = undefined;
            inline for (comptime std.meta.fieldNames(Sub)) |field_name| {
                @field(sub, field_name) = @field(node, field_name);
            }
            const name = concat(name_stack ++ .{node.name});
            try self.visit(name, @unionInit(Node, @tagName(tag), sub));
        }

        inline fn visit(self: ScannerT, name: [:0]const u8, node: Node) Err!void {
            try self.fptr(self.ctx, name, node);
        }

        fn concat(comptime list: []const []const u8) [:0]const u8 {
            const res = comptime blk: {
                var len: usize = 0;
                for (list) |s| len += s.len + 1;
                var res = std.mem.zeroes([len:0]u8);
                var offset: usize = 0;
                for (list) |s| {
                    res[offset] = '.';
                    offset += 1;
                    @memcpy(res[offset .. offset + s.len], s);
                    offset += s.len;
                }
                break :blk res;
            };

            return &res;
        }
    };
}
