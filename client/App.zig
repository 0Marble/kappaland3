const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
pub const Log = @import("Log.zig");
const gl = @import("gl");

win: *c.SDL_Window,
gl_ctx: c.SDL_GLContext,
gl_procs: gl.ProcTable,
debug_alloc: std.heap.DebugAllocator(.{}),

const App = @This();
var ok = false;
var app: *App = undefined;

pub fn init() !void {
    if (ok) return;
    Log.log(.debug, "Initialization...", .{});

    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    errdefer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();
    app = try gpa.create(App);
    errdefer gpa.destroy(app);
    app.debug_alloc = debug_alloc;

    try init_sdl();
    try init_gl();

    Log.log(.debug, "Started the client", .{});
    ok = true;
}

fn init_sdl() !void {
    Log.log(.debug, "Initialization: SDL...", .{});
    try sdl_call(c.SDL_Init(c.SDL_INIT_VIDEO));
    Log.log(.debug, "Initialized SDL", .{});
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, gl.info.version_major));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, gl.info.version_minor));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_FLAGS, c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLEBUFFERS, 1));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLESAMPLES, 4));
    Log.log(.debug, "Set OpenGL attributes", .{});

    app.win = try sdl_call(c.SDL_CreateWindow("Client", 640, 480, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL));
    Log.log(.debug, "Created SDL Window", .{});
    Log.log(.debug, "Initialized SDL", .{});
}

fn init_gl() !void {
    Log.log(.debug, "Initialization: OpenGL...", .{});
    app.gl_ctx = try sdl_call(c.SDL_GL_CreateContext(app.win));
    try sdl_call(c.SDL_GL_MakeCurrent(app.win, app.gl_ctx));
    try sdl_call(app.gl_procs.init(&c.SDL_GL_GetProcAddress));
    gl.makeProcTableCurrent(&app.gl_procs);
    try gl_call(gl.Enable(gl.DEPTH_TEST));
    try gl_call(gl.Enable(gl.MULTISAMPLE));
    Log.log(.debug, "Initialized OpenGL", .{});
}

pub fn deinit() void {
    if (!ok) return;
    var alloc = app.debug_alloc;
    const gpa = alloc.allocator();

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();
    gpa.destroy(app);
    _ = alloc.deinit();

    ok = false;
}

pub fn run() !void {
    while (handle_events()) {
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            Log.log(.warn, "Could not swap window: {s}", .{c.SDL_GetError()});
        }
    }
}

fn handle_events() bool {
    var running = true;
    var evt: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&evt)) {
        switch (evt.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_RESIZED => {},
            else => {},
        }
    }

    return running;
}
