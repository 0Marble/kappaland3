const gl = @import("gl");
const std = @import("std");
const App = @import("App.zig");
const Log = @import("libmine").Log;
const Ecs = @import("libmine").Ecs;
const gl_call = @import("util.zig").gl_call;
const zm = @import("zm");

program: gl.uint,
uniforms: std.StringHashMapUnmanaged(gl.int) = .{},
eid: Ecs.EntityRef,

pub fn observe_settings(
    self: *Shader,
    setting: []const u8,
    comptime T: type,
    comptime name: [:0]const u8,
) !void {
    const evt = try App.settings().settings_change_event(T, setting);

    const Callback = struct {
        fn callback(shader: *Shader, vals: []T) void {
            const val = vals[vals.len - 1];
            _ = switch (T) {
                bool => shader.set_uint(name, if (val) 1 else 0),
                i32 => shader.set_int(name, val),
                f32 => shader.set_float(name, val),
                else => @compileError("Todo: support type " ++ @typeName(T)),
            } catch |err| {
                Log.log(
                    .warn,
                    "{*}: could not set uniform '{s}': {}",
                    .{ shader, name, err },
                );
            };
        }
    };

    try App.ecs().add_event_listener(self.eid, T, *Shader, evt, self, Callback.callback);
}

pub const Source = struct {
    name: []const u8 = "Unnamed",
    sources: []const [:0]const u8,
    kind: gl.@"enum",
    shader_id: gl.uint = 0,

    pub fn ensure_compiled(self: *Source) !void {
        if (self.shader_id != 0) return;
        errdefer {
            Log.log(.err, "Failed to compile shader:", .{});
            for (self.sources) |s| {
                Log.log(.err, "{s}", .{s});
            }
        }

        const shader = try gl_call(gl.CreateShader(self.kind));
        try gl_call(gl.ShaderSource(
            shader,
            1,
            @ptrCast(self.sources),
            null,
        ));
        try gl_call(gl.CompileShader(shader));

        var compile_status: gl.int = gl.TRUE;
        try gl_call(gl.GetShaderiv(shader, gl.COMPILE_STATUS, @ptrCast(&compile_status)));
        if (compile_status != gl.TRUE) {
            var info_len: gl.int = 0;
            try gl_call(gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, @ptrCast(&info_len)));
            const buf = try App.frame_alloc().alloc(gl.char, @intCast(info_len + 1));

            if (info_len > 0) {
                var read: gl.sizei = 0;
                try gl_call(gl.GetShaderInfoLog(
                    shader,
                    info_len + 1,
                    &read,
                    @ptrCast(buf),
                ));
            }
            Log.log(.err, "Could not compile shader {s}:\n{s}", .{ self.name, buf });
            return error.CouldNotCompileShader;
        }

        self.shader_id = shader;
        Log.log(.debug, "Compiled shader '{s}', kind: {X}, handle: {d}", .{ self.name, self.kind, self.shader_id });
    }

    pub fn deinit(self: *Source) void {
        if (self.shader_id != 0) {
            gl.DeleteShader(self.shader_id);
        }
    }
};

const Shader = @This();
pub fn init(sources: []Source) !Shader {
    const program = try gl_call(gl.CreateProgram());
    for (sources) |*s| {
        try s.ensure_compiled();
        try gl_call(gl.AttachShader(program, s.shader_id));
    }
    try gl_call(gl.LinkProgram(program));

    var link_status: gl.int = gl.TRUE;
    try gl_call(gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&link_status)));
    if (link_status == gl.FALSE) {
        var info_len: gl.int = 0;
        try gl_call(gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, @ptrCast(&info_len)));
        const buf = try App.frame_alloc().alloc(gl.char, @intCast(info_len + 1));

        if (info_len > 0) {
            var read: gl.sizei = 0;
            try gl_call(gl.GetProgramInfoLog(
                program,
                info_len,
                &read,
                @ptrCast(buf),
            ));
            Log.log(.err, "Could not link shader:\n{s}", .{buf});
            return error.CouldNotCompileShader;
        }
    }
    for (sources) |*s| {
        s.deinit();
    }

    return Shader{ .program = program, .eid = try App.ecs().spawn() };
}

pub fn deinit(self: *Shader) void {
    gl.DeleteProgram(self.program);
    self.uniforms.deinit(App.gpa());
}

pub fn bind(self: *const Shader) !void {
    try gl_call(gl.UseProgram(self.program));
}

fn get_uniform_location(self: *Shader, name: [:0]const u8) !gl.int {
    if (self.uniforms.get(name)) |old| return old;

    const loc = try gl_call(gl.GetUniformLocation(self.program, name));
    try self.uniforms.put(App.gpa(), name, loc);
    return loc;
}
pub fn set_mat4(self: *Shader, name: [:0]const u8, mat: zm.Mat4f) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.UniformMatrix4fv(loc, 1, gl.TRUE, @ptrCast(&mat)));
}
pub fn set_vec3(self: *Shader, name: [:0]const u8, vec: zm.Vec3f) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.Uniform3f(loc, vec[0], vec[1], vec[2]));
}
pub fn set_vec2(self: *Shader, name: [:0]const u8, vec: zm.Vec2f) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.Uniform2f(loc, vec[0], vec[1]));
}
pub fn set_float(self: *Shader, name: [:0]const u8, x: f32) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.Uniform1f(loc, x));
}
pub fn set_uint(self: *Shader, name: [:0]const u8, x: gl.uint) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.Uniform1ui(loc, x));
}
pub fn set_int(self: *Shader, name: [:0]const u8, x: gl.int) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    try gl_call(gl.Uniform1i(loc, x));
}
pub fn set(self: *Shader, name: [:0]const u8, val: anytype, comptime typ: []const u8) !void {
    try self.bind();
    const loc = try self.get_uniform_location(name);
    const func_name = "Uniform" ++ typ;
    try gl_call(@call(.auto, @field(gl, func_name), .{loc} ++ val));
}
