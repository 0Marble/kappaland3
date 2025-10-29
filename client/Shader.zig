const gl = @import("gl");
const std = @import("std");
const App = @import("App.zig");
const Log = @import("Log.zig");
const gl_call = @import("util.zig").gl_call;
const zm = @import("zm");
const ShaderSource = @import("ShaderSource.zig");

program: gl.uint,
uniforms: std.StringHashMapUnmanaged(gl.int) = .{},

const Shader = @This();
pub fn init(sources: []ShaderSource) !Shader {
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
        const buf = try App.temp_alloc().alloc(gl.char, @intCast(info_len + 1));

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

    return Shader{ .program = program };
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
