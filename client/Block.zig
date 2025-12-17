const std = @import("std");
const Coords = @import("Chunk.zig").Coords;
const Model = @import("BlockModel");

pub const Id = enum(u16) {
    air = 0,
    stone,
    dirt,
    grass,
};

pub const Face = enum {
    front,
    back,
    right,
    left,
    top,
    bot,

    pub fn flip(self: Face) Face {
        return switch (self) {
            .front => .back,
            .back => .front,
            .right => .left,
            .left => .right,
            .top => .bot,
            .bot => .top,
        };
    }

    pub fn front_dir(self: Face) Coords {
        return switch (self) {
            .front => .{ 0, 0, 1 },
            .back => .{ 0, 0, -1 },
            .right => .{ 1, 0, 0 },
            .left => .{ -1, 0, 0 },
            .top => .{ 0, 1, 0 },
            .bot => .{ 0, -1, 0 },
        };
    }

    pub fn left_dir(self: Face) Coords {
        return switch (self) {
            .front => .{ -1, 0, 0 },
            .back => .{ 1, 0, 0 },
            .right => .{ 0, 0, 1 },
            .left => .{ 0, 0, -1 },
            .top => .{ -1, 0, 0 },
            .bot => .{ 1, 0, 0 },
        };
    }

    pub fn up_dir(self: Face) Coords {
        return switch (self) {
            .front => .{ 0, 1, 0 },
            .back => .{ 0, 1, 0 },
            .right => .{ 0, 1, 0 },
            .left => .{ 0, 1, 0 },
            .top => .{ 0, 0, 1 },
            .bot => .{ 0, 0, 1 },
        };
    }
};
