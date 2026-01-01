const std = @import("std");
const Coords = @import("Chunk.zig").Coords;
const App = @import("App.zig");

pub const Id = enum(u16) {
    air = 0,
    stone,
    dirt,
    grass,
    planks,
    planks_slab,
    debug,

    pub fn get_texture(self: Id, face: Face) usize {
        const atlas = &App.blocks().atlas;

        switch (self) {
            .stone => return atlas.get_idx(".blocks.main.stone"),
            .planks, .planks_slab => return atlas.get_idx(".blocks.main.planks"),
            .dirt => return atlas.get_idx(".blocks.main.dirt"),
            .grass => if (face == .bot) {
                return atlas.get_idx(".blocks.main.dirt");
            } else if (face == .top) {
                return atlas.get_idx(".blocks.main.grass_top");
            } else {
                return atlas.get_idx(".blocks.main.grass_side");
            },
            else => switch (face) {
                inline else => |tag| return atlas.get_idx(".blocks.main.debug_" ++ @tagName(tag)),
            },
        }
    }
};

pub const indices: []const u8 = &.{ 0, 1, 2, 0, 2, 3 };

pub const Face = enum(u3) {
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
            .top => .{ 0, 0, -1 },
            .bot => .{ 0, 0, -1 },
        };
    }
};

pub const Model = packed struct(u32) {
    u_scale: u4,
    v_scale: u4,
    u_offset: u4,
    v_offset: u4,
    w_offset: u4,
    _unused: u12 = 0xeba,
};
