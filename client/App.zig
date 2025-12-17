const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
const gl = @import("gl");
const zm = @import("zm");
pub const Keys = @import("Keys.zig");
const EventManager = @import("libmine").EventManager;
const Options = @import("ClientOptions");
pub const DebugUi = @import("DebugUi.zig");
pub const Settings = @import("Settings.zig");
pub const Game = @import("Game.zig");

win: *c.SDL_Window,
gl_ctx: c.SDL_GLContext,
gl_procs: gl.ProcTable,

frame_memory: Arena,
static_memory: Arena,

events: EventManager,
frame_data: FrameData,
debug_ui: DebugUi,
random: std.Random.DefaultPrng,
settings_store: Settings,
keys_state: Keys,

layers: std.ArrayList(Layer),

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });
const Arena = std.heap.ArenaAllocator;

pub const UnhandledError = std.mem.Allocator.Error || util.GlError;

pub const Layer = struct {
    data: *anyopaque,

    on_attatch: *const fn (*anyopaque) anyerror!void,
    on_frame_start: *const fn (*anyopaque) UnhandledError!void,
    on_update: *const fn (*anyopaque) UnhandledError!void,
    on_frame_end: *const fn (*anyopaque) UnhandledError!void,
    on_detatch: *const fn (*anyopaque) void,
    on_resize: *const fn (*anyopaque, i32, i32) UnhandledError!void,
};

const App = @This();
var app: App = undefined;
var main_alloc: Gpa = .init;

pub fn init() !void {
    std.log.info("Initialization...", .{});

    @memset(std.mem.asBytes(&app), 0xbc);
    app.random = .init(69);

    try init_memory();
    app.settings_store = try .init();
    app.events = .init(App.main_alloc.allocator());
    app.frame_data = .{ .start = std.time.timestamp() };
    try app.keys_state.init();

    try init_sdl();
    try init_gl();
    app.debug_ui = try .init(&app);

    app.layers = .empty;
    try push_layer(Game.layer());

    std.log.info("Started the client", .{});
}

pub fn push_layer(layer: Layer) UnhandledError!void {
    try app.layers.append(App.gpa(), layer);
    layer.on_attatch(layer.data) catch |err| switch (err) {
        error.OutOfMemory, error.GlError => return @errorCast(err),
        else => {
            std.log.err("Could not attatch layer! {}", .{err});
            _ = app.layers.pop();
        },
    };
}

fn init_memory() !void {
    app.frame_memory = .init(App.gpa());
    app.static_memory = .init(App.gpa());
}

fn init_sdl() !void {
    std.log.info("Initialization: SDL...", .{});
    try sdl_call(c.SDL_Init(c.SDL_INIT_VIDEO));
    std.log.info("Initialized SDL", .{});
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, gl.info.version_major));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, gl.info.version_minor));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdl_call(c.SDL_GL_SetAttribute(
        c.SDL_GL_CONTEXT_FLAGS,
        c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG |
            if (Options.gl_debug) c.SDL_GL_CONTEXT_DEBUG_FLAG else 0,
    ));
    std.log.info("Set OpenGL attributes", .{});

    app.win = try sdl_call(c.SDL_CreateWindow(
        "Client",
        640,
        480,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL,
    ));
    std.log.info("Created SDL Window", .{});
    std.log.info("Initialized SDL", .{});
}

fn init_gl() !void {
    std.log.info("Initialization: OpenGL...", .{});
    app.gl_ctx = try sdl_call(c.SDL_GL_CreateContext(app.win));
    try sdl_call(c.SDL_GL_MakeCurrent(app.win, app.gl_ctx));
    try sdl_call(app.gl_procs.init(&c.SDL_GL_GetProcAddress));
    gl.makeProcTableCurrent(&app.gl_procs);
    try gl_call(gl.Enable(gl.CULL_FACE));
    try gl_call(gl.FrontFace(gl.CW));
    try gl_call(gl.Enable(gl.DEPTH_TEST));
    try gl_call(gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE));
    try gl_call(gl.DepthFunc(gl.GREATER));

    if (Options.gl_debug) {
        var flags: u32 = 0;
        try gl_call(gl.GetIntegerv(gl.CONTEXT_FLAGS, @ptrCast(&flags)));
        if (flags & gl.CONTEXT_FLAG_DEBUG_BIT == 0) {
            std.log.warn("Could not enable OpenGL debug output!", .{});
        } else {
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT));
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS));
            try gl_call(gl.DebugMessageCallback(&gl_debug_callback, null));
            std.log.info("Enabled OpenGL debug output", .{});
        }
    }

    std.log.info("Initialized OpenGL", .{});
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

    std.log.warn("--------", .{});
    std.log.warn("{x}:{x}:{x}:{x}: {s}", .{ source, typ, id, severity, msg });
    std.log.warn("--------", .{});
}

pub fn deinit() void {
    app.debug_ui.deinit();
    app.settings_store.deinit();
    app.events.deinit();
    app.keys_state.deinit();

    for (0..app.layers.items.len) |i| {
        const j = app.layers.items.len - 1 - i;
        const layer = app.layers.items[j];
        layer.on_detatch(layer.data);
    }

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();

    app.layers.deinit(App.gpa());
    app.frame_memory.deinit();
    app.static_memory.deinit();
    _ = App.main_alloc.deinit();
}

pub fn gpa() std.mem.Allocator {
    return main_alloc.allocator();
}

pub fn frame_alloc() std.mem.Allocator {
    return app.frame_memory.allocator();
}

pub fn static_alloc() std.mem.Allocator {
    return app.static_memory.allocator();
}

fn on_imgui(self: *App) !void {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(App.frame_alloc());
    try w.print(
        \\runtime: {f}
        \\CPU Memory: 
        \\    main:  {f}
        \\    frame: {f}
        \\
    , .{
        util.TimeFmt{ .seconds = std.time.timestamp() - self.frame_data.start },
        util.MemoryUsage.from_bytes(App.main_alloc.total_requested_bytes),
        util.MemoryUsage.from_bytes(self.frame_memory.queryCapacity()),
    });

    const mem_str = try buf.toOwnedSliceSentinel(App.frame_alloc(), 0);
    c.igText("%s", mem_str.ptr);
}

pub fn run() UnhandledError!void {
    while (true) {
        app.frame_data.on_frame_start();

        if (!try handle_events()) break;

        app.debug_ui.on_frame_start();
        try gui().add_to_frame(App, "Debug", &app, on_imgui, @src());
        try app.settings_store.on_imgui();
        try app.keys_state.on_frame_start();

        for (0..app.layers.items.len) |i| {
            const j = app.layers.items.len - i - 1;
            const layer = app.layers.items[j];
            try layer.on_frame_start(layer.data);
        }

        app.events.process();
        for (0..app.layers.items.len) |i| {
            const j = app.layers.items.len - i - 1;
            const layer = app.layers.items[j];
            try layer.on_update(layer.data);
        }

        app.debug_ui.draw();

        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            std.log.warn("Could not swap window: {s}", .{c.SDL_GetError()});
        }

        for (0..app.layers.items.len) |i| {
            const j = app.layers.items.len - i - 1;
            const layer = app.layers.items[j];
            try layer.on_frame_end(layer.data);
        }

        try app.keys_state.on_frame_end();
        app.frame_data.on_frame_end();
        _ = app.frame_memory.reset(.{ .retain_capacity = {} });
    }
}

fn handle_events() !bool {
    var running = true;
    var evt: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&evt)) {
        if (gui().handle_event(&evt) == .captured) continue;

        switch (evt.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_RESIZED => {
                gl.Viewport(0, 0, evt.window.data1, evt.window.data2);
                for (0..app.layers.items.len) |i| {
                    const j = app.layers.items.len - 1 - i;
                    const layer = app.layers.items[j];
                    try layer.on_resize(layer.data, evt.window.data1, evt.window.data2);
                }
            },
            c.SDL_EVENT_KEY_DOWN => {
                try keys().emit_keydown(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_KEY_UP => {
                try keys().emit_keyup(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                keys().emit_mouse_down(.from_sdl(evt.button.button));
                keys().emit_mouse_motion(evt.button.x, evt.button.y);
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                keys().emit_mouse_up(.from_sdl(evt.button.button));
                keys().emit_mouse_motion(evt.button.x, evt.button.y);
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                keys().emit_mouse_motion(evt.motion.x, evt.motion.y);
            },
            else => {},
        }
    }

    return running;
}

pub fn frametime() f32 {
    return @floatFromInt(app.frame_data.frame_end_time - app.frame_data.frame_start_time);
}

pub fn event_manager() *EventManager {
    return &app.events;
}

pub fn current_frame() u64 {
    return app.frame_data.cur_frame;
}

pub fn screen_width() i32 {
    var w: i32 = 0;
    sdl_call(c.SDL_GetWindowSize(app.win, &w, null)) catch return 0;
    return w;
}
pub fn screen_height() i32 {
    var h: i32 = 0;
    sdl_call(c.SDL_GetWindowSize(app.win, null, &h)) catch return 0;
    return h;
}

pub fn rng() std.Random {
    return app.random.random();
}

pub fn settings() *Settings {
    return &app.settings_store;
}

pub fn keys() *Keys {
    return &app.keys_state;
}

pub fn gui() *DebugUi {
    return &app.debug_ui;
}

const FrameData = struct {
    cur_frame: u64 = 0,
    last_fps_measurement_frame: u64 = 0,
    last_fps_measurement_time: i64 = 0,
    frame_start_time: i64 = 0,
    frame_end_time: i64 = 0,
    this_frame_start: i64 = 0,
    start: i64,

    fn on_frame_start(self: *FrameData) void {
        self.this_frame_start = std.time.milliTimestamp();

        if (self.this_frame_start >= self.last_fps_measurement_time + 1000) {
            const frame_cnt: f32 = @floatFromInt(self.cur_frame - self.last_fps_measurement_frame);
            const dt: f32 = @floatFromInt(self.this_frame_start - self.last_fps_measurement_time);
            const fps = frame_cnt / dt * 1000.0;
            const str = std.fmt.allocPrintSentinel(
                frame_alloc(),
                "FPS: {d:4.2}",
                .{fps},
                0,
            ) catch |err| blk: {
                std.log.warn("Could not allocate a string for FPS measurement: {}", .{err});
                break :blk "FPS: ???";
            };
            sdl_call(c.SDL_SetWindowTitle(app.win, @ptrCast(str))) catch |err| {
                std.log.warn("Could not rename window: {}, fallback: fps={d:4.2}", .{ err, fps });
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
