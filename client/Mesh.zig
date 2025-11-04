const std = @import("std");
const gl = @import("gl");
const gl_call = @import("util.zig").gl_call;
const Log = @import("libmine").Log;

vao: gl.uint,
vbo: gl.uint,
ibo: gl.uint,
index_count: gl.sizei,
index_type: gl.@"enum",

const Mesh = @This();
pub fn init(
    comptime Vert: type,
    comptime Idx: type,
    verts: []const Vert,
    inds: []const Idx,
    usage: gl.@"enum",
) !Mesh {
    var self = std.mem.zeroes(Mesh);
    try gl_call(gl.GenVertexArrays(1, @ptrCast(&self.vao)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.vbo)));
    try gl_call(gl.GenBuffers(1, @ptrCast(&self.ibo)));

    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.BindBuffer(gl.ARRAY_BUFFER, self.vbo));
    try gl_call(gl.BufferData(
        gl.ARRAY_BUFFER,
        @intCast(verts.len * @sizeOf(Vert)),
        @ptrCast(verts),
        usage,
    ));
    Log.log(.debug, "Allocated ARRAY_BUFFER: size: {d}", .{verts.len * @sizeOf(Vert)});
    try gl_call(gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ibo));
    try gl_call(gl.BufferData(
        gl.ELEMENT_ARRAY_BUFFER,
        @intCast(inds.len * @sizeOf(Idx)),
        @ptrCast(inds),
        usage,
    ));
    Log.log(.debug, "Allocated ELEMENT_ARRAY_BUFFER: size: {d}", .{inds.len * @sizeOf(Idx)});

    try Vert.setup_attribs();

    self.index_count = @intCast(inds.len);
    self.index_type = switch (Idx) {
        u32 => gl.UNSIGNED_INT,
        u16 => gl.UNSIGNED_SHORT,
        u8 => gl.UNSIGNED_BYTE,
        else => @compileError("Invalid index type \"" ++ @typeName(Idx) ++ "\""),
    };

    return self;
}

pub fn draw(self: *Mesh, mode: gl.@"enum") !void {
    try gl_call(gl.BindVertexArray(self.vao));
    try gl_call(gl.DrawElements(mode, self.index_count, self.index_type, 0));
    try gl_call(gl.BindVertexArray(0));
}

pub fn deinit(self: *Mesh) void {
    gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
    gl.DeleteBuffers(1, @ptrCast(&self.ibo));
    gl.DeleteBuffers(1, @ptrCast(&self.vbo));
}
