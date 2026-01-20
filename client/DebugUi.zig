const std = @import("std");
const c = @import("c.zig").c;
const App = @import("App.zig");
const Options = @import("Build").Options;
const Log = @import("Log.zig");

const OOM = std.mem.Allocator.Error;

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
ctx: *c.ImGuiContext,

const DebugUi = @This();
pub fn init(app: *App) !DebugUi {
    var self = DebugUi{
        .frames = .empty,
        .ctx = undefined,
    };

    self.ctx = c.igCreateContext(null) orelse {
        std.log.err("Could not create imgui context", .{});
        return error.ImguiError;
    };
    if (!c.ig_ImplSDL3_InitForOpenGL(app.win, app.gl_ctx)) {
        std.log.err("Could not init imgui for SDL3+OpenGL", .{});
        return error.ImguiError;
    }
    if (!c.ig_ImplOpenGL3_Init("#version 460 core")) {
        std.log.err("Could not init imgui for OpenGL", .{});
        return error.ImguiError;
    }

    return self;
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
) OOM!void {
    const entry = try self.frames.getOrPutValue(App.frame_alloc(), name, .empty);
    try entry.value_ptr.append(App.frame_alloc(), .{
        .data = @ptrCast(ctx),
        .callback = @ptrCast(contents),
        .src = if (Options.ui_store_src) src else {},
    });
}

pub fn handle_event(self: *DebugUi, evt: *c.SDL_Event) void {
    _ = self;
    _ = c.ig_ImplSDL3_ProcessEvent(evt);
}

pub fn on_frame_start(self: *DebugUi) void {
    _ = self;

    c.ig_ImplOpenGL3_NewFrame();
    c.ig_ImplSDL3_NewFrame();
    c.igNewFrame();
}

pub fn draw(self: *DebugUi) void {
    for (self.frames.keys(), self.frames.values()) |frame, contents| {
        _ = c.igBegin(@ptrCast(frame), null, 0);
        for (contents.items) |cb| {
            cb.do() catch |err| {
                const err_str = @errorName(err);
                const red: c.ImVec4 = .{ .x = 1, .y = 0, .z = 0, .w = 1 };
                if (Options.ui_store_src) {
                    c.igTextColored(
                        red,
                        "[%s:%d:%d] Error: '%s'",
                        cb.src.file.ptr,
                        cb.src.line,
                        cb.src.column,
                        err_str.ptr,
                    );
                } else {
                    c.igTextColored(red, "Error: '%s'", err_str.ptr);
                }
            };
        }
        c.igEnd();
    }

    if (c.igBegin("Log", null, 0)) {
        Log.on_imgui();
        c.igEnd();
    }

    c.igRender();

    self.frames = .empty;
    c.ig_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
}
