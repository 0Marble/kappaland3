const App = @import("App.zig");
const std = @import("std");
const c = @import("c.zig").c;
const gl = @import("gl");
const zm = @import("zm");
const Block = @import("Block.zig");
const Options = @import("Build").Options;
const VFS = @import("assets/VFS.zig");

const ModelViewer = @This();

current_model: usize = 0,

const Instance = struct {
    var instance: ModelViewer = .{};
};

pub fn instance() *ModelViewer {
    return &Instance.instance;
}

pub fn layer() App.Layer {
    return .{
        .data = @ptrCast(instance()),
        .on_attach = @ptrCast(&on_attach),
        .on_detach = @ptrCast(&on_detach),
        .on_frame_start = @ptrCast(&on_frame_start),
    };
}

fn on_attach(self: *ModelViewer) App.UnhandledError!void {
    _ = self;
}

fn on_detach(self: *ModelViewer) App.UnhandledError!void {
    _ = self;
}

fn on_frame_start(self: *ModelViewer) App.UnhandledError!void {
    try App.gui().add_to_frame(ModelViewer, "Model", self, on_imgui, @src());
}

fn on_imgui(self: *ModelViewer) !void {
    const models = &App.assets().get_models().gltfs;
    const names = models.keys();
    if (c.igBeginCombo("model", @ptrCast(names[self.current_model]), 0)) {
        defer c.igEndCombo();

        for (names, 0..) |name, idx| {
            const is_selected: bool = idx == self.current_model;
            if (c.igSelectable_Bool(@ptrCast(name), is_selected, 0, .{})) {
                self.current_model = idx;
            }
        }
    }

    if (c.igButton("load", .{})) {}
}

fn on_resize(data: *c.ImGuiInputTextCallbackData) callconv(.c) i32 {
    if (data.EventFlag != c.ImGuiInputTextFlags_CallbackResize) return 0;

    const str: *std.ArrayList(u8) = @ptrCast(@alignCast(data.UserData.?));
    str.appendNTimes(App.static_alloc(), 0, @intCast(data.BufSize)) catch return -1;
    data.Buf = @ptrCast(str.items.ptr);
    return 0;
}

fn draw(self: *ModelViewer) !void {
    _ = self; // autofix
}

const Face = struct {};
