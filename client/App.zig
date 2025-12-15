const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
const gl = @import("gl");
pub const GameState = @import("GameState.zig");
const zm = @import("zm");
pub const Keys = @import("Keys.zig");
const Ecs = @import("libmine").Ecs;
const Options = @import("ClientOptions");
pub const DebugUi = @import("DebugUi.zig");
pub const Renderer = @import("Renderer.zig");
pub const Settings = @import("Settings.zig");

win: *c.SDL_Window,
gl_ctx: c.SDL_GLContext,
gl_procs: gl.ProcTable,

thread_gpa: []Gpa,
frame_memory: Arena,
static_memory: []Arena,

thread_pool: std.Thread.Pool,
main_thread_id: std.Thread.Id,

frame_data: FrameData,
game: GameState,
main_renderer: Renderer,
debug_ui: DebugUi,
random: std.Random.DefaultPrng,
settings_store: Settings,

const Gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true });
const Arena = std.heap.ArenaAllocator;

const App = @This();
var app: App = undefined;
var main_alloc: Gpa = .init;

pub fn init() !void {
    std.log.debug("Initialization...", .{});

    @memset(std.mem.asBytes(&app), 0xbc);

    try app.thread_pool.init(.{
        .allocator = App.main_alloc.allocator(),
        .track_ids = true,
    });
    app.main_thread_id = std.Thread.getCurrentId();
    try init_memory();

    app.settings_store = try .init();

    try init_sdl();
    try init_gl();
    try init_game();

    std.log.debug("Started the client", .{});
}

fn init_memory() !void {
    const thread_count = app.thread_pool.getIdCount();

    app.thread_gpa = try App.gpa().alloc(Gpa, thread_count);
    app.static_memory = try App.gpa().alloc(Arena, thread_count);

    for (0..thread_count) |i| {
        app.thread_gpa[i] = .init;
        app.static_memory[i] = .init(app.thread_gpa[i].allocator());
    }

    app.frame_memory = .init(App.gpa());
}

fn init_game() !void {
    app.frame_data = .{};
    try app.game.init();
    app.debug_ui = try .init(&app);
    try app.main_renderer.init();
    app.random = .init(69);
}

fn init_sdl() !void {
    std.log.debug("Initialization: SDL...", .{});
    try sdl_call(c.SDL_Init(c.SDL_INIT_VIDEO));
    std.log.debug("Initialized SDL", .{});
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, gl.info.version_major));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, gl.info.version_minor));
    try sdl_call(c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_PROFILE_MASK, c.SDL_GL_CONTEXT_PROFILE_CORE));
    try sdl_call(c.SDL_GL_SetAttribute(
        c.SDL_GL_CONTEXT_FLAGS,
        c.SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG |
            if (Options.gl_debug) c.SDL_GL_CONTEXT_DEBUG_FLAG else 0,
    ));
    std.log.debug("Set OpenGL attributes", .{});

    app.win = try sdl_call(c.SDL_CreateWindow(
        "Client",
        640,
        480,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_OPENGL,
    ));
    std.log.debug("Created SDL Window", .{});
    std.log.debug("Initialized SDL", .{});
}

fn init_gl() !void {
    std.log.debug("Initialization: OpenGL...", .{});
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
            std.log.debug("Enabled OpenGL debug output", .{});
        }
    }

    std.log.debug("Initialized OpenGL", .{});
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
    app.game.deinit();
    app.debug_ui.deinit();
    app.main_renderer.deinit();
    app.settings_store.deinit();
    app.thread_pool.deinit();

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();

    for (app.static_memory) |*s| s.deinit();
    for (app.thread_gpa) |*s| _ = s.deinit();
    app.frame_memory.deinit();
    App.gpa().free(app.static_memory);
    App.gpa().free(app.thread_gpa);
    _ = App.main_alloc.deinit();
}

pub fn game_state() *GameState {
    return &app.game;
}

pub fn local_gpa() std.mem.Allocator {
    const thread = std.Thread.getCurrentId();
    const id = app.thread_pool.ids.getIndex(thread).?;
    return app.thread_gpa[@intCast(id)].allocator();
}

pub fn gpa() std.mem.Allocator {
    std.debug.assert(std.Thread.getCurrentId() == app.main_thread_id);
    return main_alloc.allocator();
}

pub fn frame_alloc() std.mem.Allocator {
    std.debug.assert(std.Thread.getCurrentId() == app.main_thread_id);
    return app.frame_memory.allocator();
}

pub fn static_alloc() std.mem.Allocator {
    const thread = std.Thread.getCurrentId();
    const id = app.thread_pool.ids.getIndex(thread).?;
    return app.static_memory[@intCast(id)].allocator();
}

fn on_imgui(self: *App) !void {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(App.frame_alloc());
    try w.print(
        \\CPU Memory: 
        \\    main:  {f}
        \\    frame: {f}
        \\
    , .{
        util.MemoryUsage.from_bytes(App.main_alloc.total_requested_bytes),
        util.MemoryUsage.from_bytes(self.frame_memory.queryCapacity()),
    });

    for (0..self.thread_gpa.len) |i| {
        try w.print(
            \\    thread[{d}]: gpa: {f} static: {f}
            \\
        , .{
            i,
            util.MemoryUsage.from_bytes(self.thread_gpa[i].total_requested_bytes),
            util.MemoryUsage.from_bytes(self.static_memory[i].queryCapacity()),
        });
    }

    const mem_str = try buf.toOwnedSliceSentinel(App.frame_alloc(), 0);

    c.igText("%s", mem_str.ptr);
}

pub fn run() !void {
    while (true) {
        app.frame_data.on_frame_start();
        if (!try handle_events()) break;

        try app.debug_ui.on_frame_start();
        try gui().add_to_frame(App, "Debug", &app, on_imgui, @src());
        try app.settings_store.on_imgui();

        try app.game.on_frame_start();
        try app.main_renderer.on_frame_start();

        try app.debug_ui.update();
        try app.game.update();

        try renderer().draw();
        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            std.log.warn("Could not swap window: {s}", .{c.SDL_GetError()});
        }

        try app.game.on_frame_end();
        app.frame_data.on_frame_end();

        _ = app.frame_memory.reset(.{ .retain_capacity = {} });
    }
}

pub fn key_state() *Keys {
    return &game_state().keys;
}

pub fn gui() *DebugUi {
    return &app.debug_ui;
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
                try App.renderer().resize_framebuffers(evt.window.data1, evt.window.data2);
                game_state().camera.frustum.update_aspect(@as(f32, @floatFromInt(evt.window.data1)) /
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

pub fn renderer() *Renderer {
    return &app.main_renderer;
}

pub fn rng() std.Random {
    return app.random.random();
}

pub fn settings() *Settings {
    return &app.settings_store;
}

pub fn pool() *std.Thread.Pool {
    return &app.thread_pool;
}

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
