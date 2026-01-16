const c = @import("c.zig").c;
const gl = @import("gl");
const std = @import("std");
const Options = @import("Build").Options;
const EventManager = @import("libmine").EventManager;
const App = @import("App.zig");

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

pub const GlError = error{GlError};
pub fn gl_call(res: anytype) GlError!@TypeOf(res) {
    if (!Options.gl_check_errors) {
        return res;
    }
    var ok = true;
    while (true) {
        const err = gl.GetError();
        if (err != gl.NO_ERROR) {
            if (gl_err_to_str(err)) |msg| {
                std.log.err("GL error: {s}", .{msg});
            } else {
                std.log.err("GL error: {X}", .{err});
            }
            ok = false;
        } else break;
    }
    if (!ok) {
        return GlError.GlError;
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
            std.log.err("SDL error: {s}", .{c.SDL_GetError()});
            return SdlError.SdlError;
        } else return,
        .optional => if (res) |x| {
            return x;
        } else {
            std.log.err("SDL error: {s}", .{c.SDL_GetError()});
            return SdlError.SdlError;
        },
        else => return res,
    }
}

pub fn Array2DFormat(comptime Elem: type) type {
    return struct {
        array: []const Elem,
        w: usize,
        h: usize,

        pub fn init(array: []const Elem, w: usize, h: usize) @This() {
            return .{ .array = array, .w = w, .h = h };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            for (0..self.h) |y| {
                const row = self.array[y * self.w .. (y + 1) * self.w];
                try writer.print("{any}\n", .{row});
            }
        }
    };
}

pub inline fn cond_capture(cond: bool, captrure: anytype) @TypeOf(captrure) {
    if (cond) return captrure;
    return null;
}

pub fn file_sdl_iostream(file: *std.fs.File) !*c.SDL_IOStream {
    const Interface = struct {
        fn size(f: *std.fs.File) callconv(.c) i64 {
            if (f.stat()) |ok| return @intCast(ok.size) else |err| {
                std.log.err("{*}: could not stat file: {}", .{ f, err });
                return -1;
            }
        }

        fn seek(f: *std.fs.File, offset: i64, whence: c.SDL_IOWhence) callconv(.c) i64 {
            _ = switch (whence) {
                c.SDL_IO_SEEK_SET => f.seekTo(@intCast(offset)),
                c.SDL_IO_SEEK_CUR => f.seekBy(@intCast(offset)),
                c.SDL_IO_SEEK_END => f.seekFromEnd(@intCast(offset)),
                else => {
                    std.debug.panic("{*}: invalid whence: {d}", .{ f, whence });
                },
            } catch |err| {
                std.log.err("{*}: could not seek: {}", .{ f, err });
                return -1;
            };

            const cur_offset = f.getPos() catch |err| {
                std.log.err("{*}: could not getPos: {}", .{ f, err });
                return -1;
            };
            return @intCast(cur_offset);
        }

        fn read(f: *std.fs.File, ptr: [*]u8, len: usize, status: *c.SDL_IOStatus) callconv(.c) usize {
            var buf: []u8 = undefined;
            buf.ptr = ptr;
            buf.len = len;
            const read_amt = f.read(buf) catch |err| {
                std.log.err("{*}: could not read: {}", .{ f, err });
                status.* = c.SDL_IO_STATUS_ERROR;
                return 0;
            };
            return read_amt;
        }

        fn write(f: *std.fs.File, ptr: [*]const u8, len: usize, status: *c.SDL_IOStatus) callconv(.c) usize {
            var buf: []const u8 = undefined;
            buf.ptr = ptr;
            buf.len = len;
            return f.write(buf) catch |err| {
                std.log.err("{*}: could not write: {}", .{ f, err });
                status.* = c.SDL_IO_STATUS_ERROR;
                return 0;
            };
        }

        fn flush(f: *std.fs.File, status: *c.SDL_IOStatus) callconv(.c) bool {
            f.sync() catch |err| {
                std.log.err("{*}: could not flush: {}", .{ f, err });
                status.* = c.SDL_IO_STATUS_ERROR;
                return false;
            };
            return true;
        }

        fn close(f: *std.fs.File) callconv(.c) bool {
            f.close();
            return true;
        }
    };

    var iface = c.SDL_IOStreamInterface{
        .version = @sizeOf(c.SDL_IOStreamInterface),
        .size = @ptrCast(&Interface.size),
        .seek = @ptrCast(&Interface.seek),
        .read = @ptrCast(&Interface.read),
        .write = @ptrCast(&Interface.write),
        .flush = @ptrCast(&Interface.flush),
    };

    const res = try sdl_call(c.SDL_OpenIO(@ptrCast(&iface), @ptrCast(file)));
    return res;
}

pub const AmountPerSecond = struct {
    amt: usize = 0,
    evt: EventManager.Event = .invalid,
    handle: EventManager.EventListenerHandle = undefined,
    measurement: f32 = 0.0,

    pub fn add(self: *AmountPerSecond, amt: usize) void {
        if (self.evt == .invalid) {
            self.evt = App.event_manager().get_named(".main.second_passed").?;
            _ = App.event_manager().add_listener(self.evt, callback, .{self}, @src()) catch
                unreachable;
        }
        self.amt += amt;
    }

    fn callback(self: *AmountPerSecond, ms: f32) void {
        self.measurement = @as(f32, @floatFromInt(self.amt)) / ms * 1000.0;
        self.amt = 0;
    }
};
