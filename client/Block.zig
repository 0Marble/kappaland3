const std = @import("std");
const Coords = @import("Chunk.zig").Coords;
const App = @import("App.zig");

idx: u16,

const Block = @This();
pub const invalid: Block = .{ .idx = .invalid };

pub fn from_int(x: anytype) Block {
    return .{ .idx = @intCast(x) };
}

pub fn to_int(self: Block, comptime Int: type) Int {
    return @intCast(self.idx);
}

pub fn get_textures(self: Block, face: Face) []const usize {
    const info = App.assets().get_blocks().get_info(self);
    return info.textures.get(face).?;
}

pub fn get_model(self: Block, face: Face) []const usize {
    const info = App.assets().get_blocks().get_info(self);
    return info.model.get(face).?;
}

pub fn is_solid(self: Block, face: Face) bool {
    const info = App.assets().get_blocks().get_info(self);
    return info.solid.get(face).?;
}

pub fn casts_ao(self: Block) bool {
    const info = App.assets().get_blocks().get_info(self);
    return info.casts_ao;
}

pub fn air() Block {
    return App.assets().get_blocks().air;
}

pub fn dirt() Block {
    return App.assets().get_blocks().dirt;
}

pub fn stone() Block {
    return App.assets().get_blocks().stone;
}

pub fn grass() Block {
    return App.assets().get_blocks().grass;
}

pub fn is_air(self: Block) bool {
    return self.idx == air().idx;
}

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
    u_scale: u4 = 15,
    v_scale: u4 = 15,
    u_offset: u4 = 0,
    v_offset: u4 = 0,
    w_offset: u4 = 0,
    _unused: u12 = 0xeba,
};
