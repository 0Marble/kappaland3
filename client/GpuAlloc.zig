const gl = @import("gl");
const gl_call = @import("util.zig").gl_call;

const std = @import("std");
const Options = @import("ClientOptions");

const logger = std.log.scoped(.gpu_alloc);

pub const Handle = enum(usize) {
    const OFFSET = 2;

    invalid = 0,
    empty = 1,

    _,

    fn to_idx(self: Handle) usize {
        return @intFromEnum(self) - OFFSET;
    }

    fn from_idx(idx: usize) Handle {
        return @enumFromInt(idx + OFFSET);
    }
};

buffer: gl.uint,
initial_size: usize,
size: usize,
usage: Usage,
gpa: std.mem.Allocator,

allocations: std.ArrayList(Entry), // there is always a sentinel entry at the end
freelist: std.ArrayList(usize),

const Entry = struct {
    start: usize, // offset into GpuAlloc.buffer

    offset: usize = 0, // offset from start, i.e. offset=0 => offset into GpuAlloc.buffer = start
    size: usize = 0, // used length of the Entry
    // end is the start of the next Entry
};

const GpuAlloc = @This();
const Usage = gl.uint;
pub fn init(gpa: std.mem.Allocator, size: usize, usage: Usage) !GpuAlloc {
    var self = GpuAlloc{
        .buffer = 0,
        .initial_size = size,
        .size = 0,
        .gpa = gpa,
        .usage = usage,
        .allocations = .empty,
        .freelist = .empty,
    };
    try gl_call(gl.CreateBuffers(1, @ptrCast(&self.buffer)));

    try self.allocations.append(self.gpa, .{
        .start = 0,
    });

    return self;
}

fn allocation_end(self: *GpuAlloc, idx: usize) usize {
    if (idx + 1 == self.allocations.items.len) {
        return self.size;
    }
    return self.allocations.items[idx + 1].start;
}

fn try_fit_allocation(
    self: *GpuAlloc,
    idx: usize,
    size: usize,
    alignment: std.mem.Alignment,
) bool {
    const entry = &self.allocations.items[idx];
    const end = self.allocation_end(idx);

    const offset = alignment.forward(entry.start) - entry.start;
    if (entry.start + offset + size >= end) return false;

    entry.offset = offset;
    entry.size = size;
    return true;
}

pub fn alloc(self: *GpuAlloc, size: usize, alignment: std.mem.Alignment) !Handle {
    if (size == 0) return .empty;

    logger.debug("{*}: alloc({}, {})", .{ self, size, alignment });

    for (self.freelist.items, 0..) |old, i| {
        if (self.try_fit_allocation(old, size, alignment)) {
            _ = self.freelist.swapRemove(i);
            const handle = Handle.from_idx(old);

            logger.debug("{*}: alloc({}, {}): reuse {}", .{ self, size, alignment, handle });
            return handle;
        }
    }

    const last_idx = self.allocations.items.len - 1;
    if (self.try_fit_allocation(last_idx, size, alignment)) {
        const a = self.allocations.items[last_idx];
        const new_sentinel = try self.allocations.addOne(self.gpa);
        new_sentinel.* = .{
            .start = @min(a.start + a.offset + a.size * 2, self.size),
        };
        std.debug.assert(a.start + a.offset + a.size < new_sentinel.start);

        const handle = Handle.from_idx(last_idx);
        logger.debug("{*}: alloc({}, {}): allocate {}@{}-{}", .{
            self,
            size,
            alignment,
            handle,
            a.start,
            new_sentinel.start,
        });
        std.debug.assert(@as(isize, @intCast(size)) == self.get_range(handle).?.size);

        return handle;
    } else {
        try self.full_realloc();
        return self.alloc(size, alignment);
    }
}

pub fn realloc(
    self: *GpuAlloc,
    handle: Handle,
    new_size: usize,
    alignment: std.mem.Alignment,
) !Handle {
    if (new_size == 0) {
        self.free(handle);
        return .empty;
    }
    if (handle == .empty or handle == .invalid) return self.alloc(new_size, alignment);

    logger.debug("{*}: realloc({}, {})", .{ self, handle, new_size });

    const idx = handle.to_idx();
    const entry = &self.allocations.items[idx];
    const end = self.allocation_end(idx);
    if (entry.start + entry.offset + new_size < end) {
        entry.size = new_size;
        logger.debug("{*}: realloc({}, {}): expanded", .{ self, handle, new_size });
        return handle;
    }

    const new = try self.alloc(new_size, alignment);
    const old_region = self.get_range(handle).?;
    const new_region = self.get_range(new).?;

    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.buffer));
    try gl_call(gl.CopyBufferSubData(
        gl.ARRAY_BUFFER,
        gl.ARRAY_BUFFER,
        old_region.offset,
        new_region.offset,
        old_region.size,
    ));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));

    logger.debug("{*}: realloc({}, {}): allocated new {}", .{ self, handle, new_size, new });
    std.debug.assert(@as(isize, @intCast(new_size)) == new_region.size);
    return new;
}

pub fn free(self: *GpuAlloc, handle: Handle) void {
    if (handle == .invalid) {
        logger.warn("{*}: Freeing an invalid handle!", .{self});
    }
    if (handle == .empty) return;

    const idx = handle.to_idx();
    const entry = &self.allocations.items[idx];
    if (entry.size == 0) {
        logger.warn("{*}: double free {}", .{ self, handle });
        return;
    }

    entry.size = 0;
    self.freelist.append(self.gpa, idx) catch |err| {
        logger.warn("{*}: couldnt put a freed entry into a freelist: {}", .{ self, err });
    };
}

pub const GpuMemoryRange = struct {
    offset: isize,
    size: isize,
};

// for glBufferSubData and the like
pub fn get_range(self: *GpuAlloc, handle: Handle) ?GpuMemoryRange {
    if (handle == .invalid) return null;

    if (handle == .empty) return .{ .offset = 0, .size = 0 };

    const idx = handle.to_idx();
    const entry = self.allocations.items[idx];
    logger.debug("{*}: get_range({}): {}", .{ self, handle, entry });
    return .{
        .offset = @intCast(entry.start + entry.offset),
        .size = @intCast(entry.size),
    };
}

pub fn deinit(self: *GpuAlloc) void {
    self.allocations.deinit(self.gpa);
    self.freelist.deinit(self.gpa);
    gl.DeleteBuffers(1, @ptrCast(&self.buffer));
}

fn full_realloc(self: *GpuAlloc) !void {
    const new_size = if (self.size == 0) self.initial_size else self.size * 2;

    if (self.size != 0) {
        var new_buf: gl.uint = 0;
        try gl_call(gl.GenBuffers(1, @ptrCast(&new_buf)));

        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, new_buf));
        try gl_call(gl.BufferData(gl.ARRAY_BUFFER, @intCast(new_size), null, self.usage));

        try gl_call(gl.BindBuffer(gl.COPY_READ_BUFFER, self.buffer));
        try gl_call(gl.CopyBufferSubData(
            gl.COPY_READ_BUFFER,
            gl.ARRAY_BUFFER,
            0,
            0,
            @intCast(self.size),
        ));
        try gl_call(gl.BindBuffer(gl.COPY_READ_BUFFER, 0));

        try gl_call(gl.DeleteBuffers(1, @ptrCast(&self.buffer)));
        self.buffer = new_buf;
    } else {
        try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.buffer));
        try gl_call(gl.BufferData(gl.ARRAY_BUFFER, @intCast(new_size), null, self.usage));
    }
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, 0));
    self.size = new_size;
    logger.info("{*}: Allocated {Bi:.2} on the gpu", .{ self, self.size });
}
