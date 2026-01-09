const App = @import("App.zig");
const std = @import("std");
const Camera = @import("Camera.zig");
const c = @import("c.zig").c;
const Renderer = @import("Renderer.zig");
pub const ChunkManager = @import("ChunkManager.zig");
const Options = @import("Build").Options;
const Chunk = @import("Chunk.zig");
const Coords = @import("Chunk.zig").Coords;
const CHUNK_SIZE = @import("Chunk.zig").CHUNK_SIZE;
const Block = @import("Block.zig");
const Model = @import("ModelRenderer.zig").Model;
const zm = @import("zm");

const logger = std.log.scoped(.game);

const Game = @This();
const WIDTH = Options.world_size;
const HEIGHT = Options.world_height;

camera: Camera,
renderer: Renderer,
chunk_manager: *ChunkManager,
current_selected_block: Block,

const Instance = struct {
    var instance: Game = undefined;
};

pub fn layer() App.Layer {
    return App.Layer{
        .data = @ptrCast(&Instance.instance),
        .on_attach = @ptrCast(&on_attach),
        .on_frame_start = @ptrCast(&on_frame_start),
        .on_update = @ptrCast(&on_update),
        .on_frame_end = @ptrCast(&on_frame_end),
        .on_detach = @ptrCast(&on_detach),
        .on_resize = @ptrCast(&on_resize),
    };
}

pub fn instance() *Game {
    return &Instance.instance;
}

const LOAD_MIN = -Chunk.Coords{ WIDTH / 2, HEIGHT / 2, WIDTH / 2 };
const LOAD_MAX = Chunk.Coords{ WIDTH / 2, HEIGHT / 2, WIDTH / 2 };
pub fn get_load_range(self: *Game) struct { Chunk.Coords, Chunk.Coords } {
    const cam_chunk = self.camera.chunk_coords();
    return .{ cam_chunk + LOAD_MIN, cam_chunk + LOAD_MAX };
}

fn on_attach(self: *Game) !void {
    self.current_selected_block = Block.stone();

    logger.info("{*}: initializing camera", .{self});
    self.camera.init(std.math.pi * 0.5, 1.0) catch |err| {
        std.debug.panic("TODO: controls should be set up in Settings/Keys: {}", .{err});
    };
    errdefer self.camera.deinit();
    logger.info("{*}: initializing renderer", .{self});
    try self.renderer.init();
    errdefer self.renderer.deinit();
    logger.info("{*}: initializing ChunkManager", .{self});
    self.chunk_manager = try ChunkManager.init(.{
        .thread_cnt = 4,
    });
    errdefer self.chunk_manager.deinit();
    logger.info("{*}: Attatched", .{self});

    for (0..100) |x| {
        for (0..100) |z| {
            const m = try Model.instantiate(".models.stuff.cup");
            const mat = zm.Mat4f.translationVec3(.{
                @floatFromInt(x * 3),
                10.0,
                @floatFromInt(z * 3),
            });
            try m.set_transform(mat);
        }
    }
}

fn on_imgui(self: *Game) !void {
    const camera_str: [*:0]const u8 = @ptrCast(try std.fmt.allocPrintSentinel(
        App.frame_alloc(),
        "xyz: {:.3}, angles: {:.3}, view: {:.3}\nchunk: {}",
        .{
            self.camera.frustum.pos,
            self.camera.frustum.angles,
            self.camera.frustum.view_dir(),
            self.camera.chunk_coords(),
        },
        0,
    ));
    c.igText("%s", camera_str);
}

fn on_imgui_blocks(self: *Game) !void {
    const block_names = App.assets().get_blocks().blocks.keys();
    const cur_name: [:0]const u8 = App.assets().get_blocks().get_info(self.current_selected_block).name;

    if (c.igBeginCombo("Placed Block", @ptrCast(cur_name), 0)) {
        defer c.igEndCombo();

        for (block_names, 0..) |name, idx| {
            const is_selected: bool = idx == self.current_selected_block.to_int(usize);
            if (c.igSelectable_Bool(@ptrCast(name), is_selected, 0, .{})) {
                self.current_selected_block = .from_int(idx);
            }
        }
    }
}

fn on_frame_start(self: *Game) App.UnhandledError!void {
    try App.gui().add_to_frame(Game, "Debug", self, on_imgui, @src());
    try App.gui().add_to_frame(Game, "Blocks", self, on_imgui_blocks, @src());

    try self.chunk_manager.on_imgui();
    try self.renderer.on_frame_start();
}

fn on_update(self: *Game) App.UnhandledError!void {
    const min, const max = self.get_load_range();
    try self.chunk_manager.load_region(min, max);

    try self.chunk_manager.process();
    try self.renderer.draw();
}

fn on_frame_end(self: *Game) App.UnhandledError!void {
    _ = self;
}

fn on_resize(self: *Game, w: i32, h: i32) App.UnhandledError!void {
    try self.renderer.resize_framebuffers(w, h);
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);
    self.camera.frustum.update_aspect(width / height);
}

fn on_detach(self: *Game) void {
    self.camera.deinit();
    self.renderer.deinit();
    self.chunk_manager.deinit();
    logger.info("{*}: Detatched", .{self});
}

pub fn get_block(self: *Game, coords: Coords) ?Block {
    const chunk = self.chunk_manager.get_chunk(Chunk.world_to_chunk(coords)) orelse return null;
    return chunk.get(Chunk.world_to_block(coords));
}
