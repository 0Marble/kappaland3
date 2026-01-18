const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
const gl = @import("gl");
const zm = @import("zm");
pub const Keys = @import("Keys.zig");
const EventManager = @import("libmine").EventManager;
const Options = @import("Build").Options;
pub const DebugUi = @import("DebugUi.zig");
pub const Settings = @import("Settings.zig");
pub const Game = @import("Game.zig");
pub const Assets = @import("Assets.zig");
pub const ModelViewer = @import("ModelViewer.zig");
pub const Renderer = @import("Renderer.zig");

const logger = std.log.scoped(.app);

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
asset_manager: Assets,
renderer: Renderer,

layers: std.ArrayList(Layer),

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });
const Arena = std.heap.ArenaAllocator;

pub const UnhandledError = std.mem.Allocator.Error || util.GlError;

pub const Layer = struct {
    data: *anyopaque,

    on_attach: *const fn (*anyopaque) anyerror!void = noop,
    on_frame_start: *const fn (*anyopaque) UnhandledError!void = noop,
    on_update: *const fn (*anyopaque) UnhandledError!void = noop,
    on_frame_end: *const fn (*anyopaque) UnhandledError!void = noop,
    on_detach: *const fn (*anyopaque) void = on_detatch_default,
    on_resize: *const fn (*anyopaque, i32, i32) UnhandledError!void = on_resize_default,

    fn on_resize_default(_: *anyopaque, _: i32, _: i32) UnhandledError!void {}
    fn noop(_: *anyopaque) UnhandledError!void {}
    fn on_detatch_default(_: *anyopaque) void {}
};

const App = @This();
var app: App = undefined;
var main_alloc: Gpa = .init;

pub fn init() !void {
    logger.info("Initialization...", .{});

    @memset(std.mem.asBytes(&app), 0xbc);
    app.random = .init(69);

    try init_memory();
    try init_sdl();
    try init_gl();

    app.asset_manager = try .init(App.gpa());
    app.settings_store = try .init();
    app.events = .init(App.main_alloc.allocator());
    app.frame_data = try .init();
    try app.keys_state.init();
    app.debug_ui = try .init(&app);

    logger.info("initializing renderer", .{});
    try app.renderer.init();

    app.layers = .empty;
    if (comptime std.mem.eql(u8, "game", Options.tool)) {
        try push_layer(Game.layer());
    } else if (comptime std.mem.eql(u8, "viewer", Options.tool)) {
        try push_layer(ModelViewer.layer());
    } else @compileError("Unknown tool: " ++ Options.tool);

    logger.info("Started the client", .{});
}

pub fn push_layer(layer: Layer) UnhandledError!void {
    try app.layers.append(App.gpa(), layer);
    layer.on_attach(layer.data) catch |err| switch (err) {
        error.OutOfMemory, error.GlError => return @errorCast(err),
        else => {
            logger.err("Could not attatch layer! {}", .{err});
            _ = app.layers.pop();
        },
    };
}

fn init_memory() !void {
    app.frame_memory = .init(App.gpa());
    app.static_memory = .init(App.gpa());
}

fn init_sdl() !void {
    logger.info("Initialization: SDL...", .{});
    try sdl_call(c.SDL_Init(c.SDL_INIT_VIDEO));
    logger.info("Initialized SDL", .{});
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, gl.info.version_major));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, gl.info.version_minor));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdl_call(c.SDL_GL_SetAttribute(
        c.SDL_GL_CONTEXT_FLAGS,
        c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG |
            if (Options.gl_debug) c.SDL_GL_CONTEXT_DEBUG_FLAG else 0,
    ));
    logger.info("Set OpenGL attributes", .{});

    app.win = try sdl_call(c.SDL_CreateWindow(
        "Client",
        640,
        480,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL,
    ));
    logger.info("Created SDL Window", .{});
    logger.info("Initialized SDL", .{});
}

fn init_gl() !void {
    logger.info("Initialization: OpenGL...", .{});
    app.gl_ctx = try sdl_call(c.SDL_GL_CreateContext(app.win));
    try sdl_call(c.SDL_GL_MakeCurrent(app.win, app.gl_ctx));
    try sdl_call(app.gl_procs.init(&c.SDL_GL_GetProcAddress));
    gl.makeProcTableCurrent(&app.gl_procs);
    try gl_call(gl.Enable(gl.CULL_FACE));
    try gl_call(gl.Enable(gl.DEPTH_TEST));
    try gl_call(gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE));
    try gl_call(gl.DepthFunc(gl.GREATER));

    if (Options.gl_debug) {
        var flags: u32 = 0;
        try gl_call(gl.GetIntegerv(gl.CONTEXT_FLAGS, @ptrCast(&flags)));
        if (flags & gl.CONTEXT_FLAG_DEBUG_BIT == 0) {
            logger.warn("Could not enable OpenGL debug output!", .{});
        } else {
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT));
            try gl_call(gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS));
            try gl_call(gl.DebugMessageCallback(@ptrCast(&GlDebug.callback), null));
            logger.info("Enabled OpenGL debug output", .{});
        }
    }

    logger.info("Initialized OpenGL", .{});
}

const GlDebug = struct {
    const Source = enum(u32) {
        API = gl.DEBUG_SOURCE_API,
        APPLICATION = gl.DEBUG_SOURCE_APPLICATION,
        OTHER = gl.DEBUG_SOURCE_OTHER,
        SHADER_COMPILER = gl.DEBUG_SOURCE_SHADER_COMPILER,
        THIRD_PARTY = gl.DEBUG_SOURCE_THIRD_PARTY,
        WINDOW_SYSTEM = gl.DEBUG_SOURCE_WINDOW_SYSTEM,
        _,
    };

    const Type = enum(u32) {
        DEPRECATED_BEHAVIOR = gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR,
        ERROR = gl.DEBUG_TYPE_ERROR,
        MARKER = gl.DEBUG_TYPE_MARKER,
        OTHER = gl.DEBUG_TYPE_OTHER,
        PERFORMANCE = gl.DEBUG_TYPE_PERFORMANCE,
        POP_GROUP = gl.DEBUG_TYPE_POP_GROUP,
        PORTABILITY = gl.DEBUG_TYPE_PORTABILITY,
        PUSH_GROUP = gl.DEBUG_TYPE_PUSH_GROUP,
        UNDEFINED_BEHAVIOR = gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR,
        _,
    };

    const Severity = enum(u32) {
        HIGH = gl.DEBUG_SEVERITY_HIGH,
        LOW = gl.DEBUG_SEVERITY_LOW,
        MEDIUM = gl.DEBUG_SEVERITY_MEDIUM,
        NOTIFICATION = gl.DEBUG_SEVERITY_NOTIFICATION,
    };

    fn callback(
        source: Source,
        typ: Type,
        id: u32,
        severity: Severity,
        size: i32,
        msg: [*:0]const u8,
        _: ?*const anyopaque,
    ) callconv(.c) void {
        var msg_slice: [:0]const u8 = undefined;
        msg_slice.ptr = msg;
        msg_slice.len = @intCast(size);

        logger.warn("--------", .{});
        logger.warn("{}:{}:{x}:{}: {s}", .{ source, typ, id, severity, msg });
        logger.warn("--------", .{});
        if (source != .SHADER_COMPILER and severity == .HIGH) {
            std.debug.dumpCurrentStackTrace(null);
            logger.warn("--------", .{});
        }
    }
};

pub fn deinit() void {
    logger.info("Good bye!", .{});

    for (0..app.layers.items.len) |i| {
        const j = app.layers.items.len - 1 - i;
        const layer = app.layers.items[j];
        layer.on_detach(layer.data);
    }

    app.debug_ui.deinit();
    app.settings_store.deinit();
    app.events.deinit();
    app.keys_state.deinit();
    app.asset_manager.deinit();
    app.renderer.deinit();

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();

    app.layers.deinit(App.gpa());
    app.frame_memory.deinit();
    app.static_memory.deinit();
    std.debug.assert(App.main_alloc.deinit() == .ok);
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
        \\build:   {s}
        \\pid:     {d}
        \\runtime: {D}
        \\CPU Memory: 
        \\    main:   {f}
        \\    frame:  {f}
        \\    static: {f}
        \\
    , .{
        Options.build_id,
        std.os.linux.getpid(),
        (std.time.milliTimestamp() - self.frame_data.start) * std.time.ns_per_ms,
        util.MemoryUsage.from_bytes(App.main_alloc.total_requested_bytes),
        util.MemoryUsage.from_bytes(self.frame_memory.queryCapacity()),
        util.MemoryUsage.from_bytes(self.static_memory.queryCapacity()),
    });

    const mem_str = try buf.toOwnedSliceSentinel(App.frame_alloc(), 0);
    c.igText("%s", mem_str.ptr);

    const State = struct {
        var running_perf = false;
        var perf_pid: std.os.linux.pid_t = 0;
        var perf_started_on: i64 = 0;
    };

    if (!State.running_perf and c.igButton("run perf", .{})) blk: {
        const game_pid = std.os.linux.getpid();

        State.perf_pid = std.posix.fork() catch |err| {
            logger.warn(
                "fork(): could not start perf-record process: {}",
                .{err},
            );
            break :blk;
        };
        std.debug.assert(State.perf_pid != -1);

        if (State.perf_pid != 0) {
            logger.info("starting perf-record process {d}", .{State.perf_pid});
            State.running_perf = true;
            State.perf_started_on = app.frame_data.frame_start_time;
            break :blk;
        }

        run_perf(game_pid) catch |err| {
            logger.err("(perf-record): failed {}", .{err});
        };
        std.process.exit(0);
    } else if (State.running_perf and c.igButton("stop perf", .{})) blk: {
        std.posix.kill(State.perf_pid, std.posix.SIG.INT) catch |err| {
            logger.err("could not kill perf-record: {}", .{err});
        };
        logger.info("waiting for perf-record to exit...", .{});
        const waitpid = std.posix.waitpid(State.perf_pid, 0);
        logger.info(
            "perf-record: exited with status {d}",
            .{waitpid.status},
        );

        const child = std.posix.fork() catch |err| {
            logger.warn(
                "fork(): could not start perf-report process: {}",
                .{err},
            );
            break :blk;
        };

        if (child != 0) {
            State.running_perf = false;
            logger.info("starting perf-report process {d}", .{child});
            break :blk;
        }

        perf_flamegraph() catch |err| {
            logger.err("(perf-report): failed {}", .{err});
        };
        std.process.exit(0);
    }
    if (State.running_perf) {
        c.igSameLine(0, 0);
        const elapsed = try std.fmt.allocPrintSentinel(
            App.frame_alloc(),
            "{D}",
            .{(app.frame_data.frame_start_time - State.perf_started_on) * std.time.ns_per_ms},
            0,
        );
        c.igText("%s", elapsed.ptr);
    }
}

fn perf_flamegraph() !void {
    logger.info("(perf-report) starting", .{});
    const res: std.posix.ExecveError!void = std.posix.execvpeZ(
        "perf",
        &.{ "perf", "script", "report", "flamegraph" },
        &.{},
    );

    res catch |err| {
        logger.err("(perf-report): could not start process: {}", .{err});
        return err;
    };
}

fn run_perf(parent: std.os.linux.pid_t) !void {
    var buf = std.mem.zeroes([256]u8);
    const pid_str = try std.fmt.bufPrintZ(&buf, "{d}", .{parent});

    logger.info("(perf-record) starting", .{});
    const res: std.posix.ExecveError!void = std.posix.execvpeZ(
        "perf",
        &.{ "perf", "record", "-F", "99", "-a", "-g", "-p", pid_str },
        &.{},
    );

    res catch |err| {
        logger.err("(perf-record): could not start process: {}", .{err});
        return err;
    };
}

pub fn run() UnhandledError!void {
    while (true) {
        app.frame_data.on_frame_start() catch |err| {
            logger.err("frame_data: {}", .{err});
        };

        if (!try handle_events()) break;

        app.debug_ui.on_frame_start();
        try gui().add_to_frame(App, "Debug", &app, on_imgui, @src());
        try app.settings_store.on_imgui();
        try app.keys_state.on_frame_start();
        try app.renderer.on_frame_start();

        for (0..app.layers.items.len) |i| {
            const j = app.layers.items.len - i - 1;
            const layer = app.layers.items[j];
            try layer.on_frame_start(layer.data);
        }

        try gl_call(gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT));

        app.events.process();
        for (0..app.layers.items.len) |i| {
            const j = app.layers.items.len - i - 1;
            const layer = app.layers.items[j];
            try layer.on_update(layer.data);
        }

        app.debug_ui.draw();

        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            logger.warn("Could not swap window: {s}", .{c.SDL_GetError()});
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
        gui().handle_event(&evt);
        const io: *c.ImGuiIO = @ptrCast(c.igGetIO_Nil());

        switch (evt.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_RESIZED => {
                gl.Viewport(0, 0, evt.window.data1, evt.window.data2);
                for (0..app.layers.items.len) |i| {
                    const j = app.layers.items.len - 1 - i;
                    const layer = app.layers.items[j];
                    try layer.on_resize(layer.data, evt.window.data1, evt.window.data2);
                }
                try app.renderer.resize_framebuffers(evt.window.data1, evt.window.data2);
            },
            c.SDL_EVENT_KEY_DOWN => {
                if (!io.WantCaptureKeyboard) try keys().emit_keydown(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_KEY_UP => {
                if (!io.WantCaptureKeyboard) try keys().emit_keyup(.from_sdl(evt.key.scancode));
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (!io.WantCaptureMouse) {
                    keys().emit_mouse_down(.from_sdl(evt.button.button));
                    keys().emit_mouse_motion(evt.button.x, evt.button.y);
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (!io.WantCaptureMouse) {
                    keys().emit_mouse_up(.from_sdl(evt.button.button));
                    keys().emit_mouse_motion(evt.button.x, evt.button.y);
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (!io.WantCaptureMouse) {
                    keys().emit_mouse_motion(evt.motion.x, evt.motion.y);
                }
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

pub fn elapsed_time() f32 {
    return @as(f32, @floatFromInt(app.frame_data.this_frame_start - app.frame_data.start)) / 1000.0;
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

pub fn assets() *Assets {
    return &app.asset_manager;
}

pub fn get_renderer() *Renderer {
    return &app.renderer;
}

const FrameData = struct {
    cur_frame: u64 = 0,
    last_fps_measurement_frame: u64 = 0,
    last_fps_measurement_time: i64 = 0,
    frame_start_time: i64 = 0,
    frame_end_time: i64 = 0,
    this_frame_start: i64 = 0,
    start: i64,
    evt: EventManager.Event,

    fn init() !FrameData {
        const evt = try App.event_manager().register_event(f32);
        try App.event_manager().name_event(evt, ".main.second_passed");

        return .{ .start = std.time.milliTimestamp(), .evt = evt };
    }

    fn on_frame_start(self: *FrameData) !void {
        self.this_frame_start = std.time.milliTimestamp();

        if (self.this_frame_start >= self.last_fps_measurement_time + 1000) {
            const frame_cnt: f32 = @floatFromInt(self.cur_frame - self.last_fps_measurement_frame);
            const dt: f32 = @floatFromInt(self.this_frame_start - self.last_fps_measurement_time);
            try App.event_manager().emit(self.evt, dt);

            const fps = frame_cnt / dt * 1000.0;
            const str = std.fmt.allocPrintSentinel(
                frame_alloc(),
                "FPS: {d:4.2}",
                .{fps},
                0,
            ) catch |err| blk: {
                logger.warn("Could not allocate a string for FPS measurement: {}", .{err});
                break :blk "FPS: ???";
            };
            sdl_call(c.SDL_SetWindowTitle(app.win, @ptrCast(str))) catch |err| {
                logger.warn("Could not rename window: {}, fallback: fps={d:4.2}", .{ err, fps });
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

pub fn log_fn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const builtin = @import("builtin");
    if (builtin.mode != .Debug and @intFromEnum(level) > @intFromEnum(std.log.Level.warn)) return;

    switch (scope) {
        .chunk_manager, .block_renderer, .gpu_alloc => {
            if (@intFromEnum(level) > @intFromEnum(std.log.Level.info)) {
                return;
            }
        },
        else => {},
    }

    const prefix = "[" ++ @tagName(level) ++ "] " ++ "[" ++ @tagName(scope) ++ "]: ";
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    nosuspend stderr.print(prefix ++ fmt ++ "\n", args) catch return;
}
