const std = @import("std");
const Game = @import("Game.zig");
const Chunk = @import("Chunk.zig");
const Coords = Chunk.Coords;
const CHUNK_SIZE = Chunk.CHUNK_SIZE;
const Block = @import("Block.zig");
const zm = @import("zm");

t: f32,
hit_coords: Coords,
prev_coords: Coords,
block: Block.Id,

const Raycast = @This();

pub fn raycast(ray: zm.Rayf, max_t: f32) ?Raycast {
    const one: zm.Vec3f = @splat(1);

    var cur_t: f32 = 0;
    var r = ray;
    var mul = one;
    for (0..3) |i| {
        if (r.direction[i] < 0) {
            r.direction[i] *= -1;
            r.origin[i] *= -1;
            mul[i] = -1;
        }
    }
    var prev_block = Chunk.to_world_coord(ray.origin);

    var iter_cnt: usize = 0;
    while (cur_t <= max_t) : (iter_cnt += 1) {
        if (iter_cnt >= 100) {
            std.log.warn("The raycasting bug: {}", .{ray});
            std.log.warn("Goodbye!", .{});
            std.debug.assert(false);
        }

        const cur_pos = r.at(cur_t);

        const dx = @select(f32, @ceil(cur_pos) == cur_pos, one, @ceil(cur_pos) - cur_pos);
        var dt = dx / r.direction;

        const eps = 1e-4;
        var j: usize = 0;
        if (dt[j] > dt[1]) j = 1;
        if (dt[j] > dt[2]) j = 2;
        dt[j] += eps;

        const cur_block = Chunk.to_world_coord(r.at(cur_t + 0.5 * dt[j]) * mul);
        const block = Game.instance().get_block(cur_block);

        if (block != null and block.? != .air) {
            return Raycast{
                .t = cur_t,
                .block = block.?,
                .hit_coords = cur_block,
                .prev_coords = prev_block,
            };
        }

        cur_t += dt[j];
        prev_block = cur_block;
    }
    return null;
}
