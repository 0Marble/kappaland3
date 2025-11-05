const c = @import("c.zig").c;
const Log = @import("libmine").Log;
const gl = @import("gl");
const std = @import("std");
const Options = @import("ClientOptions");

pub fn Xyz(comptime T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,
        z: T = 0,

        pub fn init(x: T, y: T, z: T) @This() {
            return .{ .x = x, .y = y, .z = z };
        }

        pub fn add(self: @This(), other: @This()) @This() {
            return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
        }
        pub fn sub(self: @This(), other: @This()) @This() {
            return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
        }
        pub fn as_vec(self: @This()) @Vector(3, T) {
            return .{ self.x, self.y, self.z };
        }
    };
}

pub const MemoryUsage = struct {
    bytes: usize,

    pub fn from_bytes(bytes: anytype) MemoryUsage {
        return .{
            .bytes = @intCast(bytes),
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.bytes) {
            0...1024 - 1 => {
                try writer.print("{d}B", .{self.bytes});
            },
            1024...1024 * 1024 - 1 => {
                const num = @as(f64, @floatFromInt(self.bytes)) / 1024;
                try writer.print("{d:.2}KB", .{num});
            },
            1024 * 1024...1024 * 1024 * 1024 - 1 => {
                const num = @as(f64, @floatFromInt(self.bytes)) / (1024 * 1024);
                try writer.print("{d:.2}MB", .{num});
            },
            else => {
                const num = @as(f64, @floatFromInt(self.bytes)) / (1024 * 1024 * 1024);
                try writer.print("{d:.2}GB", .{num});
            },
        }
    }
};

fn gl_err_to_str(code: gl.@"enum") ?[]const u8 {
    return switch (code) {
        gl.NO_ERROR => "GL_NO_ERROR",
        gl.INVALID_ENUM => "GL_INVALID_ENUM",
        gl.INVALID_VALUE => "GL_INVALID_VALUE",
        gl.INVALID_OPERATION => "GL_INVALID_OPERATION",
        gl.INVALID_FRAMEBUFFER_OPERATION => "GL_INVALID_FRAMEBUFFER_OPERATION",
        gl.OUT_OF_MEMORY => "GL_OUT_OF_MEMORY",
        gl.STACK_UNDERFLOW => "GL_STACK_UNDERFLOW",
        gl.STACK_OVERFLOW => "GL_STACK_OVERFLOW",
        else => null,
    };
}

pub fn gl_call(res: anytype) !@TypeOf(res) {
    if (!Options.gl_check_errors) {
        return res;
    }
    var ok = true;
    while (true) {
        const err = gl.GetError();
        if (err != gl.NO_ERROR) {
            if (gl_err_to_str(err)) |msg| {
                Log.log(.err, "GL error: {s}", .{msg});
            } else {
                Log.log(.err, "GL error: {X}", .{err});
            }
            ok = false;
        } else break;
    }
    if (!ok) {
        return error.GlError;
    }
    return res;
}

pub const SdlError = error{SdlError};
fn sdl_res_type(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .bool => SdlError!void,
        .optional => |x| SdlError!x.child,
        else => SdlError!T,
    };
}

pub fn sdl_call(res: anytype) sdl_res_type(@TypeOf(res)) {
    switch (@typeInfo(@TypeOf(res))) {
        .bool => if (!res) {
            Log.log(.err, "SDL error: {s}", .{c.SDL_GetError()});
            return SdlError.SdlError;
        } else return,
        .optional => if (res) |x| {
            return x;
        } else {
            Log.log(.err, "SDL error: {s}", .{c.SDL_GetError()});
            return SdlError.SdlError;
        },
        else => return res,
    }
}
