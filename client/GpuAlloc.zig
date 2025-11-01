const builtin = @import("builtin");
const gl = if (builtin.is_test) void else @import("gl");
const gl_call = if (builtin.is_test) undefined else @import("util.zig").gl_call;

const Log = @import("libmine").Log;
const std = @import("std");
const Queue = @import("libmine").queue.Queue;
const Options = @import("ClientOptions");

pub const Handle = enum(usize) {
    const OFFSET = @intFromEnum(Handle.last_reserved) + 1;
    invalid = 0,
    last_reserved = 1,
    _,

    fn from_index(idx: usize) Handle {
        return @enumFromInt(idx + Handle.OFFSET);
    }

    fn is_index(self: Handle) bool {
        return @intFromEnum(self) >= OFFSET;
    }

    fn to_index(self: Handle) usize {
        return @intFromEnum(self) - OFFSET;
    }
};

const Entry = struct {
    start: usize,
    used_size: usize,
};

buffer: if (builtin.is_test) void else gl.uint,
initial_length: usize,
length: usize,
usage: Usage,
entries: std.ArrayListUnmanaged(Entry),
freelist: Queue(usize),
gpa: std.mem.Allocator,

const GpuAlloc = @This();
const Usage = if (builtin.is_test) void else gl.uint;
pub fn init(gpa: std.mem.Allocator, length: usize, usage: Usage) !GpuAlloc {
    var self = GpuAlloc{
        .buffer = 0,
        .entries = .empty,
        .freelist = .empty,
        .initial_length = length,
        .length = 0,
        .gpa = gpa,
        .usage = usage,
    };
    try gl_call(gl.CreateBuffers(1, @ptrCast(&self.buffer)));

    return self;
}

fn alloc_success(self: *GpuAlloc, size: usize, handle: Handle) Handle {
    if (Options.gpu_alloc_log) {
        Log.log(.debug, "{*}: Allocated {d} bytes at {}", .{ self, size, handle });
    }
    return handle;
}

pub fn alloc(self: *GpuAlloc, size: usize) !Handle {
    var first_idx: ?usize = null;
    while (self.freelist.pop()) |idx| {
        if (first_idx == idx) {
            try self.freelist.push(self.gpa, idx);
            break;
        }

        if (first_idx == null) first_idx = idx;

        const entry = &self.entries.items[idx];
        const available_size = if (idx + 1 < self.entries.items.len)
            self.entries.items[idx + 1].start - entry.start
        else
            self.length - entry.start;
        if (available_size >= size) {
            entry.used_size = size;
            return self.alloc_success(size, .from_index(idx));
        } else {
            try self.freelist.push(self.gpa, idx);
        }
    }

    while (true) {
        const start = if (self.entries.getLastOrNull()) |end|
            end.start + end.used_size
        else
            0;

        if (start + size >= self.length) {
            const new_length = if (self.length == 0)
                self.initial_length
            else
                self.length * 2;

            if (!builtin.is_test) {
                if (self.length != 0) {
                    var new_buffer: gl.uint = 0;
                    try gl_call(gl.CreateBuffers(1, @ptrCast(&new_buffer)));
                    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, new_buffer));
                    try gl_call(gl.BufferData(gl.ARRAY_BUFFER, @intCast(new_length), null, self.usage));
                    try gl_call(gl.CopyBufferSubData(
                        gl.COPY_READ_BUFFER,
                        gl.ARRAY_BUFFER,
                        0,
                        0,
                        @intCast(self.length),
                    ));
                    try gl_call(gl.DeleteBuffers(1, @ptrCast(&self.buffer)));
                    self.buffer = new_buffer;
                } else {
                    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.buffer));
                    try gl_call(gl.BufferData(gl.ARRAY_BUFFER, @intCast(new_length), null, self.usage));
                }
            }
            self.length = new_length;
            if (Options.gpu_alloc_log) {
                Log.log(.debug, "{*}: Allocated {d} bytes on the GPU", .{ self, self.length });
            }
        } else {
            const entry = try self.entries.addOne(self.gpa);
            entry.start = start;
            entry.used_size = size;
            return self.alloc_success(size, .from_index(self.entries.items.len - 1));
        }
    }
}

pub fn realloc(self: *GpuAlloc, handle: Handle, new_size: usize) !Handle {
    if (!handle.is_index()) return .invalid;
    const idx = handle.to_index();
    if (idx >= self.entries.items.len) return .invalid;
    const entry = &self.entries.items[idx];

    const available_size = if (idx + 1 < self.entries.items.len)
        self.entries.items[idx + 1].start - entry.start
    else
        self.length - entry.start;

    if (available_size >= new_size) {
        entry.used_size = new_size;
        if (Options.gpu_alloc_log) {
            Log.log(.debug, "{*}: Reallocated {} to size {d}", .{ self, handle, new_size });
        }

        return handle;
    } else {
        const new_handle = try self.alloc(new_size);

        if (!builtin.is_test) {
            try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.buffer));
            const old_range = self.get_range(handle).?;
            const new_range = self.get_range(new_handle).?;
            try gl_call(gl.CopyBufferSubData(
                gl.ARRAY_BUFFER,
                gl.ARRAY_BUFFER,
                old_range.offset,
                new_range.offset,
                new_range.size,
            ));
        }

        self.free(handle);
        return new_handle;
    }
}

pub const GpuMemoryRange = struct {
    offset: isize,
    size: isize,
};
// for glBufferSubData and the like
pub fn get_range(self: *GpuAlloc, handle: Handle) ?GpuMemoryRange {
    if (!handle.is_index()) return null;
    const idx = handle.to_index();
    if (idx >= self.entries.items.len) return null;
    const entry = self.entries.items[idx];
    return .{
        .offset = @intCast(entry.start),
        .size = @intCast(entry.used_size),
    };
}

pub fn free(self: *GpuAlloc, handle: Handle) void {
    if (!handle.is_index()) return;
    const idx = handle.to_index();
    if (idx >= self.entries.items.len) return;
    const entry = &self.entries.items[idx];
    if (entry.used_size == 0) return;
    self.freelist.push(self.gpa, idx) catch return;
    entry.used_size = 0;

    if (Options.gpu_alloc_log) {
        Log.log(.debug, "{*}: free {}", .{ self, handle });
    }
}

pub fn deinit(self: *GpuAlloc) void {
    self.entries.deinit(self.gpa);
    self.freelist.deinit(self.gpa);
}
