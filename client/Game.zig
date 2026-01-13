const App = @import("App.zig");
const std = @import("std");
const Camera = @import("Camera.zig");
const c = @import("c.zig").c;
pub const World = @import("World.zig");
const Options = @import("Build").Options;
const Block = @import("Block.zig");
const zm = @import("zm");
pub const ModelRenderer = @import("ModelRenderer.zig");

const logger = std.log.scoped(.game);

const Game = @This();

camera: Camera,
world: *World,
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

fn on_attach(self: *Game) !void {
    self.current_selected_block = Block.stone();

    logger.info("{*}: initializing camera", .{self});
    self.camera.init(std.math.pi * 0.5, 1.0) catch |err| {
        std.debug.panic("TODO: controls should be set up in Settings/Keys: {}", .{err});
    };
    errdefer self.camera.deinit();

    logger.info("{*}: initializing world", .{self});
    self.world = try World.init();

    logger.info("{*}: Attatched", .{self});
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
    const cur_name: [:0]const u8 = App.assets().get_blocks().get_info(
        self.current_selected_block,
    ).name;

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
    try self.world.on_frame_start();
}

fn on_update(self: *Game) App.UnhandledError!void {
    try self.world.load_around(self.camera.chunk_coords());
    try self.world.update();
    try App.get_renderer().draw(&self.camera);
}

fn on_frame_end(self: *Game) App.UnhandledError!void {
    _ = self;
}

fn on_resize(self: *Game, w: i32, h: i32) App.UnhandledError!void {
    const width: f32 = @floatFromInt(w);
    const height: f32 = @floatFromInt(h);
    self.camera.frustum.update_aspect(width / height);
}

fn on_detach(self: *Game) void {
    self.camera.deinit();
    self.world.deinit();
    logger.info("{*}: Detatched", .{self});
}
