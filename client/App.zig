const c = @import("c.zig").c;
const std = @import("std");
pub const util = @import("util.zig");
const sdl_call = util.sdl_call;
const gl_call = util.gl_call;
pub const Log = @import("Log.zig");
const gl = @import("gl");
pub const Camera = @import("Camera.zig");
pub const Mesh = @import("Mesh.zig");
pub const Shader = @import("Shader.zig");
pub const ShaderSource = @import("ShaderSource.zig");
const zm = @import("zm");

win: *c.SDL_Window,
gl_ctx: c.SDL_GLContext,
gl_procs: gl.ProcTable,

main_alloc: std.heap.DebugAllocator(.{}),
temp_memory: std.heap.ArenaAllocator,
frame_memory: std.heap.ArenaAllocator,
static_memory: std.heap.ArenaAllocator,

cur_frame: u64,
last_fps_measurement_frame: u64,
last_fps_measurement_time: i64,
frame_start_time: i64,
frame_end_time: i64,

// Player
camera: Camera,
look_around: bool,
pressed: std.AutoHashMap(c.SDL_Scancode, void),

// World
mesh: Mesh,
shader: Shader,
model: zm.Mat4f,
sources: [2]ShaderSource,

const App = @This();
var ok = false;
var app: *App = undefined;

pub fn init() !void {
    if (ok) return;
    Log.log(.debug, "Initialization...", .{});

    var debug_alloc = std.heap.DebugAllocator(.{}).init;
    app = try debug_alloc.allocator().create(App);
    @memset(std.mem.asBytes(app), 0xbc);
    app.main_alloc = debug_alloc;

    app.cur_frame = 0;
    app.last_fps_measurement_frame = 0;
    app.last_fps_measurement_time = std.time.milliTimestamp();
    app.frame_start_time = app.last_fps_measurement_time;
    app.frame_end_time = app.last_fps_measurement_time + 1;
    app.pressed = .init(gpa());
    app.look_around = false;

    try init_memory();
    try init_sdl();
    try init_gl();
    try init_scene();

    Log.log(.debug, "Started the client", .{});
    ok = true;
}

fn init_memory() !void {
    app.temp_memory = .init(gpa());
    app.frame_memory = .init(gpa());
    app.static_memory = .init(gpa());
}

fn init_scene() !void {
    app.sources = .{
        .{
            .sources = &.{vert_src},
            .kind = gl.VERTEX_SHADER,
            .name = "vert",
        },
        .{
            .sources = &.{frag_src},
            .kind = gl.FRAGMENT_SHADER,
            .name = "frag",
        },
    };
    app.shader = try Shader.init(&app.sources);

    const Vert = packed struct {
        pos: packed struct { x: f32, y: f32, z: f32 },
        norm: packed struct { x: f32, y: f32, z: f32 },

        pub fn setup_attribs() !void {
            inline for (comptime std.meta.fieldNames(@This()), 0..) |attrib, i| {
                const size = std.meta.fields(@FieldType(@This(), attrib)).len;
                std.log.debug("{s}: location: {d}, len: {d}, stride: {d}, offset: {d}", .{
                    attrib,
                    i,
                    size,
                    @sizeOf(@This()),
                    @offsetOf(@This(), attrib),
                });
                try gl_call(gl.VertexAttribPointer(
                    i,
                    @intCast(size),
                    gl.FLOAT,
                    gl.FALSE,
                    @sizeOf(@This()),
                    @offsetOf(@This(), attrib),
                ));
                try gl_call(gl.EnableVertexAttribArray(i));
            }
        }
    };
    const verts: []const Vert = &.{
        .{ .pos = .{ .x = -1, .y = -1, .z = 0 }, .norm = .{ .x = 0, .y = 0, .z = 1 } },
        .{ .pos = .{ .x = -1, .y = 1, .z = 0 }, .norm = .{ .x = 0, .y = 0, .z = 1 } },
        .{ .pos = .{ .x = 1, .y = 1, .z = 0 }, .norm = .{ .x = 0, .y = 0, .z = 1 } },
        .{ .pos = .{ .x = 1, .y = -1, .z = 0 }, .norm = .{ .x = 0, .y = 0, .z = 1 } },
    };
    const inds: []const u16 = &.{ 0, 1, 2, 0, 2, 3 };
    app.mesh = try Mesh.init(Vert, u16, verts, inds, gl.STATIC_DRAW);
    app.camera = Camera.init(std.math.pi * 0.5, 640.0 / 480.0);

    try app.shader.bind();
    app.model = zm.Mat4f.translation(0, -1, -5)
        .multiply(zm.Mat4f.scaling(5, 1, 5)
        .multiply(zm.Mat4f.rotation(.{ 1, 0, 0 }, -std.math.pi * 0.5)));
    const material = [_]f32{ 0.2125, 0.1275, 0.054, 0.714, 0.4284, 0.18144, 0.393548, 0.271906, 0.166721, 0.2 };
    try app.shader.set_mat4("u_model", app.model);
    try app.shader.set_mat4("u_transp_inv_model", app.model.inverse().transpose());
    try app.shader.set_vec3("u_light_pos", .{ 0, 1, 0 });
    try app.shader.set_vec3("u_ambient", material[0..3].*);
    try app.shader.set_vec3("u_diffuse", material[3..6].*);
    try app.shader.set_vec3("u_specular", material[6..9].*);
    try app.shader.set_float("u_shininess", material[9] * 128.0);
    try app.shader.set_vec3("u_light_color", .{ 1, 1, 0.9 });

    gl.ClearColor(0.3, 0.5, 0.7, 1.0);

    Log.log(.debug, "Loaded the scene", .{});
}
const vert_src =
    \\#version 460 core
    \\layout (location = 0) in vec3 vert_pos;
    \\layout (location = 1) in vec3 vert_norm;
    \\
    \\uniform mat4 u_mvp;
    \\uniform mat4 u_model;
    \\uniform mat4 u_transp_inv_model;
    \\out vec3 frag_normal;
    \\out vec3 frag_pos;
    \\
    \\void main() {
    \\frag_normal = (u_transp_inv_model * vec4(vert_norm, 1)).xyz;
    \\frag_pos = (u_model * vec4(vert_pos, 1)).xyz;
    \\gl_Position = u_mvp * vec4(vert_pos, 1);
    \\}
;
const frag_src =
    \\#version 460 core
    \\
    \\uniform vec3 u_ambient;
    \\uniform vec3 u_diffuse;
    \\uniform vec3 u_specular;
    \\uniform float u_shininess;
    \\uniform vec3 u_light_color;
    \\uniform vec3 u_light_pos;
    \\uniform vec3 u_view_pos;
    \\
    \\in vec3 frag_normal;
    \\in vec3 frag_pos;
    \\out vec4 out_frag_color;
    \\
    \\void main() {
    \\vec3 ambient = u_light_color * u_ambient;
    \\
    \\vec3 norm = normalize(frag_normal);
    \\vec3 light_dir = normalize(u_light_pos - frag_pos);
    \\float diff = max(dot(norm, light_dir), 0.0);
    \\vec3 diffuse = u_light_color * diff * u_diffuse;
    \\
    \\float spec = 0.0;
    \\if (diff > 0.0) {
    \\vec3 view_dir = normalize(u_view_pos - frag_pos);
    \\vec3 half_dir = normalize(light_dir + view_dir);
    \\spec = pow(max(dot(half_dir, frag_normal), 0.0), u_shininess);
    \\}
    \\vec3 specular = u_light_color * spec * u_specular;
    \\
    \\vec3 result = ambient + diffuse + specular;
    \\out_frag_color = vec4(result, 1);
    \\}
    \\
;

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

    app.mesh.deinit();
    app.shader.deinit();

    gl.makeProcTableCurrent(null);
    _ = c.SDL_GL_MakeCurrent(app.win, null);
    _ = c.SDL_GL_DestroyContext(app.gl_ctx);
    c.SDL_DestroyWindow(app.win);
    c.SDL_Quit();

    app.pressed.deinit();
    app.static_memory.deinit();
    app.frame_memory.deinit();
    app.temp_memory.deinit();
    var main_alloc = app.main_alloc;
    main_alloc.allocator().destroy(app);
    _ = main_alloc.deinit();

    ok = false;
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
    while (true) {
        const this_frame_start = std.time.milliTimestamp();

        if (this_frame_start > app.last_fps_measurement_time + 1000) {
            const frame_cnt: f32 = @floatFromInt(app.cur_frame - app.last_fps_measurement_frame);
            const dt: f32 = @floatFromInt(this_frame_start - app.last_fps_measurement_time);
            const fps = frame_cnt / dt * 1000.0;
            const str = try std.fmt.allocPrintSentinel(temp_alloc(), "FPS: {d:4.2}", .{fps}, 0);
            try sdl_call(c.SDL_SetWindowTitle(app.win, @ptrCast(str)));
            app.last_fps_measurement_time = this_frame_start;
            app.last_fps_measurement_frame = app.cur_frame;
        }

        _ = app.frame_memory.reset(.{ .retain_capacity = {} });

        if (!try handle_events()) break;
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const vp = app.camera.as_mat();
        try app.shader.set_mat4("u_mvp", vp.multiply(app.model));
        try app.shader.set_vec3("u_view_pos", app.camera.pos);

        try app.shader.bind();
        try app.mesh.draw(gl.TRIANGLES);

        if (!c.SDL_GL_SwapWindow(@ptrCast(app.win))) {
            Log.log(.warn, "Could not swap window: {s}", .{c.SDL_GetError()});
        }
        app.cur_frame += 1;

        app.frame_start_time = this_frame_start;
        app.frame_end_time = std.time.milliTimestamp();
    }
}

fn handle_events() !bool {
    var running = true;
    var evt: c.SDL_Event = undefined;
    const MOVEMENT_SPEED = 0.01;
    const MOUSE_SPEED = 0.001;
    const dt = frametime();

    while (c.SDL_PollEvent(&evt)) {
        switch (evt.type) {
            c.SDL_EVENT_QUIT => running = false,
            c.SDL_EVENT_WINDOW_RESIZED => {
                app.camera.update_aspect(@as(f32, @floatFromInt(evt.window.data1)) / @as(f32, @floatFromInt(evt.window.data2)));
                gl.Viewport(0, 0, evt.window.data1, evt.window.data2);
            },
            c.SDL_EVENT_KEY_DOWN => {
                try app.pressed.put(evt.key.scancode, {});
            },
            c.SDL_EVENT_KEY_UP => {
                _ = app.pressed.remove(evt.key.scancode);
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (evt.button.button == 2) {
                    app.look_around = true;
                    try sdl_call(c.SDL_SetWindowRelativeMouseMode(app.win, true));
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (evt.button.button == 2) {
                    app.look_around = false;
                    try sdl_call(c.SDL_SetWindowRelativeMouseMode(app.win, false));
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (app.look_around) {
                    app.camera.turn_right(evt.motion.xrel * dt * MOUSE_SPEED);
                    app.camera.turn_up(evt.motion.yrel * dt * MOUSE_SPEED);
                }
            },
            else => {},
        }
    }

    if (app.pressed.contains(c.SDL_SCANCODE_W)) {
        app.camera.move_forward(dt * MOVEMENT_SPEED);
    }
    if (app.pressed.contains(c.SDL_SCANCODE_S)) {
        app.camera.move_forward(-dt * MOVEMENT_SPEED);
    }
    if (app.pressed.contains(c.SDL_SCANCODE_A)) {
        app.camera.move_right(-dt * MOVEMENT_SPEED);
    }
    if (app.pressed.contains(c.SDL_SCANCODE_D)) {
        app.camera.move_right(dt * MOVEMENT_SPEED);
    }
    if (app.pressed.contains(c.SDL_SCANCODE_SPACE)) {
        app.camera.move_up(dt * MOVEMENT_SPEED);
    }
    if (app.pressed.contains(c.SDL_SCANCODE_LSHIFT)) {
        app.camera.move_up(-dt * MOVEMENT_SPEED);
    }

    return running;
}

pub fn frametime() f32 {
    return @floatFromInt(app.frame_end_time - app.frame_start_time);
}
