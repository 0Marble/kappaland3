const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
const Log = @import("libmine").Log;
const gl = @import("gl");
pub const GameState = @import("GameState.zig");
const zm = @import("zm");
const Keys = @import("Keys.zig");
const Ecs = @import("libmine").Ecs;
const World = @import("World.zig");
const Options = @import("ClientOptions");

win: *c.SDL_Window,
gl_ctx: c.SDL_GLContext,
gl_procs: gl.ProcTable,

main_alloc: std.heap.DebugAllocator(.{}),
temp_memory: std.heap.ArenaAllocator,
frame_memory: std.heap.ArenaAllocator,
static_memory: std.heap.ArenaAllocator,

frame_data: FrameData,
game: GameState,

world: World,

const App = @This();
var ok = false;
var app: *App = undefined;

const FrameData = struct {
    cur_frame: u64 = 0,
    last_fps_measurement_frame: u64 = 0,
    last_fps_measurement_time: i64 = 0,
    frame_start_time: i64 = 0,
    frame_end_time: i64 = 0,
    this_frame_start: i64 = 0,

    fn on_frame_start(self: *FrameData) void {
        self.this_frame_start = std.time.milliTimestamp();

        if (self.this_frame_start >= self.last_fps_measurement_time + 1000) {
            const frame_cnt: f32 = @floatFromInt(self.cur_frame - self.last_fps_measurement_frame);
            const dt: f32 = @floatFromInt(self.this_frame_start - self.last_fps_measurement_time);
            const fps = frame_cnt / dt * 1000.0;
            const str = std.fmt.allocPrintSentinel(temp_alloc(), "FPS: {d:4.2}", .{fps}, 0) catch |err| blk: {
                Log.log(.warn, "Could not allocate a string for FPS measurement: {}", .{err});
                break :blk "FPS: ???";
            };
            sdl_call(c.SDL_SetWindowTitle(app.win, @ptrCast(str))) catch |err| {
                Log.log(.warn, "Could not rename window: {}, fallback: fps={d:4.2}", .{ err, fps });
            };
            self.last_fps_measurement_time = self.this_frame_start;
            self.last_fps_measurement_frame = self.cur_frame;
        }
    }

    fn on_frame_end(self: *FrameData) void {
        self.frame_start_time = self.this_frame_start;
        self.frame_end_time = std.time.milliTimestamp();
        self.cur_frame += 1;
    }
};

pub fn init() !void {
    if (ok) return;
    Log.log(.debug, "Initialization...", .{});

    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    app = try debug_alloc.allocator().create(App);
    @memset(std.mem.asBytes(app), 0xbc);
    app.main_alloc = debug_alloc;

    try init_memory();
    try init_sdl();
    try init_gl();
    try init_gamestate();

    Log.log(.debug, "Started the client", .{});
    ok = true;
}

fn init_memory() !void {
    app.temp_memory = .init(gpa());
    app.frame_memory = .init(gpa());
    app.static_memory = .init(gpa());
}

fn init_gamestate() !void {
    app.frame_data = .{};
    try app.game.init();
    app.world = try .init();
}

fn init_sdl() !void {
    Log.log(.debug, "Initialization: SDL...", .{});
    try sdl_call(c.SDL_Init(c.SDL_INIT_VIDEO));
    Log.log(.debug, "Initialized SDL", .{});
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, gl.info.version_major));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, gl.info.version_minor));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdl_call(c.SDL_GL_SetAttribute(
        c.SDL_GL_CONTEXT_FLAGS,
        c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG |
            if (Options.gl_debug) c.SDL_GL_CONTEXT_DEBUG_FLAG else 0,
    ));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLEBUFFERS, 1));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_MULTISAMPLESAMPLES, 4));
    Log.log(.debug, "Set OpenGL attributes", .{});

    app.win = try sdl_call(c.SDL_CreateWindow(
        "Client",
        640,
        480,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL,
    ));
    Log.log(.debug, "Created SDL Window", .{});
    Log.log(.debug, "Initialized SDL", .{});
}

fn init_gl() !void {
    Log.log(.debug, "Initialization: OpenGL...", .{});
    app.gl_ctx = try sdl_call(c.SDL_GL_CreateContext(app.win));
    try sdl_call(c.SDL_GL_MakeCurrent(app.win, app.gl_ctx));
    try sdl_call(app.gl_procs.init(&c.SDL_GL_GetProcAddress));
    gl.makeProcTableCurrent(&app.gl_procs);
    try gl_call(gl.Enable(gl.MULTISAMPLE));
    // try gl_call(gl.Enable(gl.CULL_FACE));
    // try gl_call(gl.FrontFace(gl.CW));
    try gl_call(gl.Enable(gl.DEPTH_TEST));
    try gl_call(gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE));
    try gl_call(gl.DepthFunc(gl.GREATER));

    if (Options.gl_debug) {
        var flags: u32 = 0;
        try gl_call(gl.GetIntegerv(gl.CONTEXT_FLAGS, @ptrCast(&flags)));
        if (flags & gl.CONTEXT_FLAG_DEBUG_BIT == 0) {
            Log.log(.warn, "Could not enable OpenGL debug output!", .{});
        } else {
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT));
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS));
            try gl_call(gl.DebugMessageCallback(&gl_debug_callback, null));
            Log.log(.debug, "Enabled OpenGL debug output", .{});
        }
    }

    Log.log(.debug, "Initialized OpenGL", .{});
}

fn gl_debug_callback(
    source: gl.@"enum",
    typ: gl.@"enum",
    id: u32,
    severity: gl.@"enum",
    size: i32,
    msg: [*:0]const u8,
    _: ?*const anyopaque,
) callconv(.c) void {
    var msg_slice: [:0]const u8 = undefined;
    msg_slice.ptr = msg;
    msg_slice.len = @intCast(size);

    Log.log(.warn, "--------", .{});
    Log.log(.warn, "{x}:{x}:{x}:{x}: {s}", .{ source, typ, id, severity, msg });
    Log.log(.warn, "--------", .{});
}

pub fn deinit() void {
    if (!ok) return;

    app.game.deinit();
    app.world.deinit();

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();

    app.static_memory.deinit();
    app.frame_memory.deinit();
    app.temp_memory.deinit();
    var main_alloc = app.main_alloc;
    main_alloc.allocator().destroy(app);
    _ = main_alloc.deinit();

    ok = false;
}

pub fn game_state() *GameState {
    return &app.game;
}

pub fn gpa() std.mem.Allocator {
    return app.main_alloc.allocator();
}

pub fn temp_alloc() std.mem.Allocator {
    _ = app.temp_memory.reset(.{ .retain_with_limit = 1 << 16 });
    return app.temp_memory.allocator();
}

pub fn frame_alloc() std.mem.Allocator {
    return app.frame_memory.allocator();
}

pub fn run() !void {
    try gl_call(gl.ClearColor(0.4, 0.4, 0.4, 1.0));
    try gl_call(gl.ClearDepth(0.0));

    while (true) {
        app.frame_data.on_frame_start();
        if (!try handle_events()) break;

        try app.game.on_frame_start();

        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        try app.game.update();
        try app.world.draw();

        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            Log.log(.warn, "Could not swap window: {s}", .{c.SDL_GetError()});
        }

        try app.game.on_frame_end();
        app.frame_data.on_frame_end();
        try app.world.process_chunks();

        _ = app.frame_memory.reset(.{ .retain_capacity = {} });
    }
}

pub fn key_state() *Keys {
    return &game_state().keys;
}

fn handle_events() !bool {
    var running = true;
    var evt: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&evt)) {
        switch (evt.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_RESIZED => {
                gl.Viewport(0, 0, evt.window.data1, evt.window.data2);
                game_state().camera.update_aspect(@as(f32, @floatFromInt(evt.window.data1)) /
                    @as(f32, @floatFromInt(evt.window.data2)));
            },
            c.SDL_EVENT_KEY_DOWN => {
                try key_state().on_keydown(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_KEY_UP => {
                try key_state().on_keyup(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                key_state().on_mouse_down(.from_sdl(evt.button.button));
                key_state().on_mouse_motion(evt.button.x, evt.button.y);
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                key_state().on_mouse_up(.from_sdl(evt.button.button));
                key_state().on_mouse_motion(evt.button.x, evt.button.y);
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                key_state().on_mouse_motion(evt.motion.x, evt.motion.y);
            },
            else => {},
        }
    }

    return running;
}

pub fn frametime() f32 {
    return @floatFromInt(app.frame_data.frame_end_time - app.frame_data.frame_start_time);
}

pub fn ecs() *Ecs {
    return &game_state().ecs;
}

pub fn current_frame() u64 {
    return app.frame_data.cur_frame;
}
