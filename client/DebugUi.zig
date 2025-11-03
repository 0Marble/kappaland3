const std = @import("std");
const c = @import("c.zig").c;
const Log = @import("libmine").Log;
const App = @import("App.zig");
const Options = @import("ClientOptions");

const ContentsCallback = struct {
    src: if (Options.ui_store_src) std.builtin.SourceLocation else void,
    data: *anyopaque,
    callback: *const fn (*anyopaque) anyerror!void,

    fn do(self: ContentsCallback) !void {
        try self.callback(self.data);
    }
};

const FrameContentsMap = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(ContentsCallback));
frames: FrameContentsMap,

const DebugUi = @This();
pub fn init(app: *App) !DebugUi {
    _ = c.igCreateContext(null) orelse {
        Log.log(.err, "Could not create imgui context", .{});
        return error.ImguiError;
    };
    if (!c.ig_ImplSDL3_InitForOpenGL(app.win, app.gl_ctx)) {
        Log.log(.err, "Could not init imgui for SDL3+OpenGL", .{});
        return error.ImguiError;
    }
    if (!c.ig_ImplOpenGL3_Init("#version 460 core")) {
        Log.log(.err, "Could not init imgui for OpenGL", .{});
        return error.ImguiError;
    }

    return .{
        .frames = .empty,
    };
}

pub fn deinit(self: *DebugUi) void {
    _ = self;
    c.ig_ImplOpenGL3_Shutdown();
    c.ig_ImplSDL3_Shutdown();
    c.igDestroyContext(null);
}

pub fn add_to_frame(
    self: *DebugUi,
    comptime Ctx: type,
    name: [:0]const u8,
    ctx: *Ctx,
    contents: *const fn (ctx: *Ctx) anyerror!void,
    src: std.builtin.SourceLocation,
) !void {
    const entry = try self.frames.getOrPutValue(App.frame_alloc(), name, .empty);
    try entry.value_ptr.append(App.frame_alloc(), .{
        .data = @ptrCast(ctx),
        .callback = @ptrCast(contents),
        .src = if (Options.ui_store_src) src else {},
    });
}

pub const EventStatus = enum { captured, fallthrough };
pub fn handle_event(self: *DebugUi, evt: *c.SDL_Event) EventStatus {
    _ = self;
    _ = c.ig_ImplSDL3_ProcessEvent(evt);
    return .fallthrough;
}

pub fn on_frame_start(self: *DebugUi) !void {
    _ = self;

    c.ig_ImplOpenGL3_NewFrame();
    c.ig_ImplSDL3_NewFrame();
    c.igNewFrame();
}

pub fn update(self: *DebugUi) !void {
    for (self.frames.keys(), self.frames.values()) |frame, contents| {
        _ = c.igBegin(@ptrCast(frame), null, 0);
        for (contents.items) |cb| {
            try cb.do();
        }
        c.igEnd();
    }

    c.igRender();
}

pub fn on_frame_end(self: *DebugUi) !void {
    self.frames = .empty;
    c.ig_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
}
