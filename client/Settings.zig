const std = @import("std");
const App = @import("App.zig");
const Options = @import("ClientOptions");
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const EventManager = @import("libmine").EventManager;

map: Map,
events: std.StringHashMapUnmanaged(EventManager.Event),
save_on_exit: bool,

const Map = std.StringArrayHashMapUnmanaged(Node);

const OOM = std.mem.Allocator.Error;

const Settings = @This();
pub fn init() !Settings {
    var self: Settings = .{
        .events = .empty,
        .map = .empty,
        .save_on_exit = true,
    };
    try self.load_template();
    self.load() catch |err| {
        std.log.warn("Could not load settings file: {}", .{err});
    };

    return self;
}

fn load_template(self: *Settings) OOM!void {
    const Visitor = struct {
        fn add_node_callback(this: *Settings, name: [:0]const u8, node: Node) OOM!void {
            try this.set_value(name, node);
        }
    };
    try Scanner(*Settings, OOM).scan(self, &Visitor.add_node_callback);
}

pub fn deinit(self: *Settings) void {
    self.save() catch |err| {
        std.log.warn("Couldn't save settings: {}", .{err});
    };
}

fn set_value(self: *Settings, name: [:0]const u8, val: Node) OOM!void {
    if (self.events.get(name)) |evt| {
        switch (std.meta.activeTag(val)) {
            .section => {},
            inline else => |tag| {
                App.event_manager().emit(evt, @field(val, @tagName(tag)).value) catch |err| {
                    std.log.warn("Settings.set_value: Couldn't emit event: {}", .{err});
                };
            },
        }
    }

    try self.map.put(App.static_alloc(), name, val);
}

const LoadError = error{ ParseZon, ZonSchemaError } || std.fs.File.ReadError || OOM || std.fs.File.OpenError;
pub fn load(self: *Settings) LoadError!void {
    var file = try std.fs.cwd().openFile(Options.settings_file, .{});
    defer file.close();

    const len = (try file.stat()).size;
    const source = try App.frame_alloc().allocSentinel(u8, len, 0);
    _ = try file.read(source);

    const ast = try std.zig.Ast.parse(App.frame_alloc(), source, .zon);
    const zoir = try std.zig.ZonGen.generate(App.frame_alloc(), ast, .{});
    try report_zoir_errors(ast, zoir);

    const Visitor = struct {
        settings: *Settings,
        zoir: Zoir,
        ast: Ast,

        const Zoir = std.zig.Zoir;
        const ZonIndex = std.zig.Zoir.Node.Index;
        const Ast = std.zig.Ast;
        const Visitor = @This();

        fn callback(this: *Visitor, name: [:0]const u8, node: Node) LoadError!void {
            const root = ZonIndex.root.get(this.zoir);
            if (root != .struct_literal) {
                const ast_node = ZonIndex.root.getAstNode(this.zoir);
                const tok = this.ast.nodeMainToken(ast_node);
                const loc = this.ast.tokenLocation(0, tok);
                std.log.warn("Settings file invalid, expected an array_literal: {s}:{d}:{d}", .{
                    Options.settings_file,
                    loc.line,
                    loc.column,
                });
            }

            for (root.struct_literal.names, 0..) |name_ref, i| {
                if (std.mem.eql(u8, name, name_ref.get(this.zoir))) {
                    const value_node = root.struct_literal.vals.at(@intCast(i));

                    switch (std.meta.activeTag(node)) {
                        .section => unreachable,
                        inline else => |tag| {
                            const Value = @FieldType(@FieldType(Node, @tagName(tag)), "value");
                            const val = try std.zon.parse.fromZoirNode(
                                Value,
                                App.static_alloc(),
                                this.ast,
                                this.zoir,
                                value_node,
                                null,
                                .{ .ignore_unknown_fields = true },
                            );

                            var old = this.settings.map.get(name).?;
                            @field(old, @tagName(tag)).value = val;
                            try this.settings.set_value(name, old);
                        },
                    }

                    return;
                }
            }
        }
    };

    var visitor = Visitor{
        .settings = self,
        .zoir = zoir,
        .ast = ast,
    };
    try Scanner(*Visitor, LoadError).scan(&visitor, Visitor.callback);
}

fn report_zoir_errors(ast: std.zig.Ast, zoir: std.zig.Zoir) error{ZonSchemaError}!void {
    if (zoir.hasCompileErrors()) {
        std.log.warn("Couldn't parse settings file: invalid ZON:", .{});
        for (zoir.compile_errors) |err| {
            std.log.warn("{s}", .{err.msg.get(zoir)});
            for (err.getNotes(zoir)) |note| {
                if (note.token.unwrap()) |tok| {
                    const loc = ast.tokenLocation(note.node_or_offset, tok);
                    std.log.warn("{s}:{d}:{d}: {s}", .{
                        Options.settings_file,
                        loc.line,
                        loc.column,
                        note.msg.get(zoir),
                    });
                } else {
                    std.log.warn("{s}: {s}", .{
                        Options.settings_file,
                        note.msg.get(zoir),
                    });
                }
            }
        }

        return error.ZonSchemaError;
    }
}

const SaveError = std.zon.Serializer.Error || std.Io.Writer.Error || std.fs.File.OpenError;
pub fn save(self: *Settings) SaveError!void {
    const Visitor = struct {
        settings: *Settings,
        struct_builder: *std.zon.Serializer.Struct,

        const Visitor = @This();
        fn save_node_callback(this: *Visitor, name: [:0]const u8, node: Node) SaveError!void {
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
    try Scanner(*Visitor, SaveError).scan(&visitor, Visitor.save_node_callback);

    try struct_builder.end();
    try writer.interface.flush();
}

pub fn settings_change_event(
    self: *Settings,
    name: []const u8,
) (error{NoSuchSetting} || OOM)!EventManager.Event {
    if (self.map.get(name)) |n| {
        switch (std.meta.activeTag(n)) {
            .section => unreachable,
            inline else => |tag| {
                const Value = @FieldType(@FieldType(Node, @tagName(tag)), "value");
                const entry = try self.events.getOrPut(App.static_alloc(), name);
                if (entry.found_existing) return entry.value_ptr.*;

                const evt = try App.event_manager().register_event(Value);
                entry.value_ptr.* = evt;
                App.event_manager().emit(
                    evt,
                    @field(@field(n, @tagName(tag)), "value"),
                ) catch |err| switch (err) {
                    OOM.OutOfMemory => return @errorCast(err),
                    else => unreachable,
                };
                return evt;
            },
        }
    } else {
        return error.NoSuchSetting;
    }
}

pub fn get_value(self: *Settings, comptime T: type, name: []const u8) ?T {
    const node = self.map.get(name) orelse {
        std.log.warn("Attempted to access non-existant setting: {s}", .{name});
        return null;
    };
    switch (std.meta.activeTag(node)) {
        .section => unreachable,
        inline else => |tag| {
            const Body = @FieldType(Node, @tagName(tag));
            const Value = @FieldType(Body, "value");
            if (Value != T) {
                std.log.warn("Setting '{s}' type mismatch, expected {s} got {s}", .{
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

pub fn on_imgui(self: *Settings) OOM!void {
    try App.gui().add_to_frame(Settings, "Settings", self, on_imgui_impl, @src());
}

fn emit_on_changed(self: *Settings, name: []const u8, node: *const Node) void {
    switch (std.meta.activeTag(node.*)) {
        .section => {},
        inline else => |tag| {
            const evt = self.events.get(name) orelse return;
            App.event_manager().emit(evt, @field(@field(node, @tagName(tag)), "value")) catch |err| {
                std.log.warn("Settings.emit_on_changed: {s}: couldn't emit event: {}", .{ name, err });
            };
        },
    }
}

fn on_imgui_impl(self: *Settings) !void {
    _ = c.igCheckbox("Save on exit", &self.save_on_exit);
    if (c.igButton("Save", .{})) {
        self.save() catch |err| {
            std.log.warn("Couldn't save settings: {}", .{err});
        };
    }
    if (c.igButton("Restore", .{})) {
        self.load_template() catch |err| {
            std.log.warn("Couldn't load settings template: {}", .{err});
        };
    }

    var it = self.map.iterator();
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
