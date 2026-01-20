const std = @import("std");
const App = @import("App.zig");
const Options = @import("Build").Options;
const c = @import("c.zig").c;
const c_str = @import("c.zig").c_str;
const EventManager = @import("libmine").EventManager;
const VFS = @import("assets/VFS.zig");
const sdl_call = @import("util.zig").sdl_call;

events: std.StringHashMapUnmanaged(EventManager.Event),
save_on_exit: bool,
map: std.StringArrayHashMapUnmanaged(Node),
arena: std.heap.ArenaAllocator,

const OOM = std.mem.Allocator.Error;
const logger = std.log.scoped(.settings);

const Settings = @This();
pub fn init() !Settings {
    var self: Settings = .{
        .events = .empty,
        .save_on_exit = true,
        .map = .empty,
        .arena = .init(App.gpa()),
    };
    try self.load_templates();
    self.load() catch |err| {
        logger.warn("Could not load settings file: {}", .{err});
    };

    return self;
}

pub fn deinit(self: *Settings) void {
    self.save() catch |err| logger.warn("Couldn't save settings: {}", .{err});
    self.arena.deinit();
}

pub fn load(self: *Settings) !void {
    var file = try std.fs.cwd().openFile(Options.settings_file, .{});
    defer file.close();
    var buf = std.mem.zeroes([256]u8);
    var reader = file.reader(&buf);
    const size = try reader.getSize();
    const src = try App.frame_alloc().allocSentinel(u8, size, 0);
    try reader.interface.readSliceAll(src);

    const zon = try VFS.Zon.from_src(.{ .src = src, .path = Options.settings_file }, App.frame_alloc());
    const root = std.zig.Zoir.Node.Index.root.get(zon.zoir).struct_literal;
    for (root.names, 0..) |key, idx| {
        const name = key.get(zon.zoir);
        var orig = self.map.get(name) orelse continue;
        switch (@as(Node.Tag, orig)) {
            .section => continue,
            .keybind => {
                const scancode = try zon.parse_node(
                    [:0]const u8,
                    self.arena.allocator(),
                    root.vals.at(@intCast(idx)),
                );
                orig.keybind.value = try sdl_call(c.SDL_GetScancodeFromName(scancode));
                try self.set_value(name, orig);
            },
            inline else => |tag| {
                const T = @FieldType(std.meta.TagPayload(Node, tag), "value");
                const val = try zon.parse_node(T, self.arena.allocator(), root.vals.at(@intCast(idx)));
                @field(orig, @tagName(tag)).value = val;
                try self.set_value(name, orig);
            },
        }
    }
}

pub fn save(self: *Settings) !void {
    var file = try std.fs.cwd().createFile(Options.settings_file, .{});
    defer file.close();
    var buf = std.mem.zeroes([256]u8);
    var writer = file.writer(&buf);

    var serializer = std.zon.Serializer{ .writer = &writer.interface };
    var struct_builder = try serializer.beginStruct(.{});
    var it = self.map.iterator();
    while (it.next()) |kv| {
        switch (@as(Node.Tag, kv.value_ptr.*)) {
            .section => {},
            .keybind => {
                const scancode_c_str: [*:0]const u8 = try sdl_call(
                    c.SDL_GetScancodeName(kv.value_ptr.keybind.value),
                );
                const end = std.mem.indexOfSentinel(u8, 0, scancode_c_str);
                var scancode: [:0]const u8 = undefined;
                scancode.ptr = scancode_c_str;
                scancode.len = end;
                try struct_builder.field(kv.key_ptr.*, scancode, .{});
            },
            inline else => |tag| {
                try struct_builder.field(
                    kv.key_ptr.*,
                    @field(kv.value_ptr.*, @tagName(tag)).value,
                    .{},
                );
            },
        }
    }
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
        logger.err("attempted to add listener for non-existant setting {s}", .{name});
        return error.NoSuchSetting;
    }
}

pub fn get_value(self: *Settings, comptime T: type, name: []const u8) T {
    const default = switch (T) {
        bool => false,
        i32 => 0,
        f32 => 0.0,
        else => @compileError("Unsupported settings value type"),
    };
    const node = self.map.get(name) orelse {
        logger.warn("Attempted to access non-existant setting: {s}", .{name});
        return default;
    };

    switch (std.meta.activeTag(node)) {
        .section => unreachable,
        inline else => |tag| {
            const Body = @FieldType(Node, @tagName(tag));
            const Value = @FieldType(Body, "value");
            if (Value != T) {
                logger.warn("Setting '{s}' type mismatch, expected {s} got {s}", .{
                    name,
                    @typeName(Value),
                    @typeName(T),
                });
                return default;
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
            App.event_manager().emit(evt, @field(
                @field(node, @tagName(tag)),
                "value",
            )) catch |err| {
                logger.warn(
                    "Settings.emit_on_changed: {s}: couldn't emit event: {}",
                    .{ name, err },
                );
            };
        },
    }
}

fn on_imgui_impl(self: *Settings) !void {
    _ = c.igCheckbox("Save on exit", &self.save_on_exit);
    if (c.igButton("Save", .{})) {
        self.save() catch |err| {
            logger.warn("Couldn't save settings: {}", .{err});
        };
    }
    if (c.igButton("Restore", .{})) {
        self.load_templates() catch |err| {
            logger.warn("Couldn't load settings template: {}", .{err});
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
            .keybind => {
                c.igPushID_Ptr(name.ptr);
                defer c.igPopID();

                const keycode: [*c]const u8 = try sdl_call(
                    c.SDL_GetScancodeName(val.keybind.value),
                );
                c.igText("%s: ", c_name);
                c.igSameLine(0, 10);

                const State = struct {
                    var changing_keybind: ?[]const u8 = null;
                };

                if (@as([*]const u8, @ptrCast(State.changing_keybind)) == name.ptr) {
                    const escape_name = try sdl_call(c.SDL_GetScancodeName(c.SDL_SCANCODE_ESCAPE));
                    c.igText("'%s' to cancel", escape_name);
                    var pressed_keys = App.keys().this_frame_pressed_keys.keyIterator();
                    if (pressed_keys.next()) |key| {
                        switch (key.scancode) {
                            c.SDL_SCANCODE_ESCAPE => {},
                            else => {
                                val.keybind.value = key.scancode;
                                self.emit_on_changed(name, val);
                            },
                        }
                        State.changing_keybind = null;
                    }
                } else if (c.igButton(keycode, .{})) {
                    State.changing_keybind = name;
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
    checkbox: Checkbox,
    int_slider: IntSlider,
    float_slider: FloatSlider,
    keybind: Keybind,

    const Tag = std.meta.Tag(Node);
    const Checkbox = struct { value: bool };
    const IntSlider = struct { min: i32, max: i32, value: i32 };
    const FloatSlider = struct { min: f32, max: f32, value: f32 };
    const Keybind = struct { value: c.SDL_Scancode };
};

const LoadCtx = struct {
    zon: VFS.Zon,
    stack: std.ArrayList([]const u8),
};

fn load_templates(self: *Settings) OOM!void {
    logger.info("scanning {s} for settings menus", .{Options.settings_dir});
    const dir: *VFS.Dir = App.assets().get_vfs().root().get_dir(
        Options.settings_dir,
    ) catch |err| {
        logger.err("could not open settings dir: {}", .{err});
        return;
    };

    dir.visit(load_template, .{self}) catch |err| {
        logger.err("could not load settings menus: {}", .{err});
    };
}

fn load_template(self: *Settings, file: *VFS.File) !void {
    const src = try file.read_all(App.frame_alloc());
    const zon = try src.parse_zon(App.frame_alloc());
    var ctx = LoadCtx{ .zon = zon, .stack = .empty };
    self.load_template_rec(&ctx, .root) catch |err| {
        logger.err("could not load settings file {s}: {}", .{ file.path, err });
        return;
    };
    logger.info("loaded settings from {s}", .{file.path});
}

fn load_template_rec(
    self: *Settings,
    ctx: *LoadCtx,
    node_idx: std.zig.Zoir.Node.Index,
) !void {
    errdefer {
        const ast_node = node_idx.getAstNode(ctx.zon.zoir);
        const tok = ctx.zon.ast.nodeMainToken(ast_node);
        const loc = ctx.zon.ast.tokenLocation(0, tok);
        logger.err(
            "at {d}:{d}\n{s}",
            .{ loc.line, loc.column, ctx.zon.ast.source[loc.line_start..loc.line_end] },
        );
    }

    const HalfParsed = struct { kind: Node.Tag, name: []const u8 };
    const header = try ctx.zon.parse_node(HalfParsed, App.frame_alloc(), node_idx);
    const HalfParsedSection = struct {
        children: []const std.zig.Zoir.Node.Index,
    };

    switch (header.kind) {
        .section => {
            try ctx.stack.append(App.frame_alloc(), header.name);
            defer _ = ctx.stack.pop();
            const sec = try ctx.zon.parse_node(HalfParsedSection, App.frame_alloc(), node_idx);
            for (sec.children, 0..) |child, i| self.load_template_rec(ctx, child) catch |err| {
                logger.err("cound not load child {d} of section {s}: {}", .{ i, header.name, err });
            };
        },
        .keybind => {
            const KeybindStr = struct { value: [:0]const u8 };
            const keybind_str = try ctx.zon.parse_node(
                KeybindStr,
                self.arena.allocator(),
                node_idx,
            );
            const scancode: c.SDL_Scancode = try sdl_call(c.SDL_GetScancodeFromName(keybind_str.value));
            const name = try self.concat(ctx.stack.items, header.name);
            try self.set_value(name, .{ .keybind = .{ .value = scancode } });
            logger.info("registered setting {s}", .{name});
        },
        inline else => |tag| {
            const T = std.meta.TagPayload(Node, tag);
            const val: T = try ctx.zon.parse_node(T, self.arena.allocator(), node_idx);
            const name = try self.concat(ctx.stack.items, header.name);
            try self.set_value(name, @unionInit(Node, @tagName(tag), val));
            logger.info("registered setting {s}", .{name});
        },
    }
}

fn concat(self: *Settings, items: []const []const u8, name: []const u8) ![:0]const u8 {
    var buf = std.ArrayList(u8).empty;
    var w = buf.writer(App.frame_alloc());
    for (items) |s| try w.print(".{s}", .{s});
    try w.print(".{s}", .{name});
    return try self.arena.allocator().dupeZ(u8, buf.items);
}

fn set_value(self: *Settings, name: [:0]const u8, val: Node) OOM!void {
    if (self.events.get(name)) |evt| {
        switch (std.meta.activeTag(val)) {
            .section => {},
            inline else => |tag| {
                App.event_manager().emit(evt, @field(val, @tagName(tag)).value) catch |err| {
                    logger.warn("Settings.set_value: Couldn't emit event: {}", .{err});
                };
            },
        }
    }

    try self.map.put(self.arena.allocator(), name, val);
}
