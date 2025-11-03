const std = @import("std");
const c = @import("c.zig").c;
const Log = @import("libmine").Log;
const App = @import("App.zig");

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

    return .{};
}

pub fn deinit(self: *DebugUi) void {
    _ = self;
    c.ig_ImplOpenGL3_Shutdown();
    c.ig_ImplSDL3_Shutdown();
    c.igDestroyContext(null);
}

pub const EventStatus = enum { captured, fallthrough };
pub fn handle_event(self: *DebugUi, evt: c.SDL_Event) EventStatus {
    _ = self;
    _ = c.ig_ImplSDL3_ProcessEvent(&evt);
    return .fallthrough;
}

pub fn on_frame_start(self: *DebugUi) !void {
    _ = self;

    c.ig_ImplOpenGL3_NewFrame();
    c.ig_ImplSDL3_NewFrame();
    c.igNewFrame();
}

pub fn update(self: *DebugUi) !void {
    _ = self;
    _ = c.igBegin("Client", null, 0);

    const pos_str: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(App.frame_alloc(), "xyz: {}, angles: {}", .{
        App.game_state().camera.pos,
        App.game_state().camera.angles,
    }, 0));
    c.igText("%s", pos_str);
    c.igEnd();
    c.igRender();
}

pub fn on_frame_end(self: *DebugUi) !void {
    _ = self;
    c.ig_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
}
