const gl = @import("gl");
const std = @import("std");
const App = @import("App.zig");
const Log = @import("Log.zig");
const gl_call = @import("util.zig").gl_call;
const zm = @import("zm");
const Shader = @import("Shader.zig");

name: []const u8 = "Unnamed",
sources: []const [:0]const u8,
kind: gl.@"enum",
shader_id: gl.uint = 0,

const Self = @This();
pub fn ensure_compiled(self: *Self) !void {
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
        const buf = try App.temp_alloc().alloc(gl.char, @intCast(info_len + 1));

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

pub fn deinit(self: *Self) void {
    if (self.shader_id != 0) {
        gl.DeleteShader(self.shader_id);
    }
}
