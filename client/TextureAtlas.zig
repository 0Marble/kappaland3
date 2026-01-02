const std = @import("std");
const App = @import("App.zig");
const gl = @import("gl");
const util = @import("util.zig");
const gl_call = @import("util.zig").gl_call;
const c = @import("c.zig").c;

const logger = std.log.scoped(.texture_atlas);

handle: gl.uint,
images: std.StringArrayHashMapUnmanaged(usize),
img_width: usize,
img_height: usize,

const TextureAtlas = @This();
pub fn init(textures_dir: []const u8, atlas_name: []const u8) !TextureAtlas {
    logger.info("scanning {s}", .{textures_dir});
    var builder = try Builder.init(atlas_name);
    defer builder.deinit();
    var dir = try std.fs.cwd().openDir(textures_dir, .{ .iterate = true });
    defer dir.close();
    try builder.scan_dir(dir);

    const w, const h = builder.get_size(0);
    const cnt = builder.images.count();
    var self = TextureAtlas{
        .handle = 0,
        .images = .empty,
        .img_height = h,
        .img_width = w,
    };

    logger.info(
        "building atlas {s}, size: {d}x{d}x{d}",
        .{ atlas_name, w, h, cnt },
    );
    try gl_call(gl.GenTextures(1, @ptrCast(&self.handle)));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.handle));
    try gl_call(gl.TexStorage3D(
        gl.TEXTURE_2D_ARRAY,
        1,
        gl.RGB8,
        @intCast(w),
        @intCast(h),
        @intCast(cnt + 1),
    ));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE));

    for (builder.images.keys(), 0..) |name, idx| {
        const surface: *c.SDL_Surface = @ptrCast(builder.images.values()[idx]);
        try util.sdl_call(c.SDL_LockSurface(surface));
        const pixels: []const u8 = @ptrCast(surface.pixels);

        const fmt: gl.@"enum", const typ: gl.@"enum" = switch (surface.format) {
            c.SDL_PIXELFORMAT_RGBA32 => .{ gl.RGBA, gl.UNSIGNED_BYTE },
            else => {
                logger.warn(
                    "{s}: unsupported pixel format: {d}",
                    .{ name, surface.format },
                );
                continue;
            },
        };

        try gl_call(gl.TexSubImage3D(
            gl.TEXTURE_2D_ARRAY,
            0, // level
            0, // xoffset
            0, // yoffset
            @intCast(idx), // zoffset
            @intCast(w), // width
            @intCast(h), // height
            1, // depth
            fmt,
            typ,
            @ptrCast(pixels),
        ));

        try util.sdl_call(c.SDL_LockSurface(surface));

        try self.images.put(App.gpa(), name, idx);
        logger.info("registered texture {s}@{d}", .{ name, idx });
    }

    try self.generate_missing();

    return self;
}

pub fn deinit(self: *TextureAtlas) void {
    gl.DeleteTextures(1, @ptrCast(&self.handle));
    self.images.deinit(App.gpa());
}

pub fn get_idx(self: *TextureAtlas, name: []const u8) usize {
    return self.images.get(name) orelse self.images.count();
}

pub fn get_idx_or_warn(self: *TextureAtlas, name: []const u8) usize {
    return self.images.get(name) orelse {
        logger.warn("missing texture: {s}", .{name});
        return self.images.count();
    };
}

pub fn get_missing(self: *TextureAtlas) usize {
    return self.images.count();
}

const Builder = struct {
    images: std.StringArrayHashMapUnmanaged([*]c.SDL_Surface),
    prefix: std.ArrayList([]const u8),

    fn init(atlas_name: []const u8) !Builder {
        var self: Builder = .{ .images = .empty, .prefix = .empty };
        try self.prefix.append(App.gpa(), atlas_name);
        return self;
    }

    fn get_size(self: *Builder, idx: usize) struct { usize, usize } {
        const prev = self.images.values()[idx];
        var prev_rect: c.SDL_Rect = .{};
        _ = c.SDL_GetSurfaceClipRect(prev, &prev_rect);
        return .{ @intCast(prev_rect.w), @intCast(prev_rect.h) };
    }

    fn scan_dir(self: *Builder, dir: std.fs.Dir) !void {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    var next_dir = try dir.openDir(entry.name, .{ .iterate = true });
                    defer next_dir.close();
                    try self.prefix.append(App.gpa(), entry.name);
                    defer _ = self.prefix.pop();
                    try self.scan_dir(next_dir);
                },
                .file => {
                    const ext = std.fs.path.extension(entry.name);
                    const name = entry.name[0 .. entry.name.len - ext.len];
                    const full_name = try concat(self.prefix.items, name);

                    var file = try dir.openFile(entry.name, .{});
                    const sdl_io = try util.file_sdl_iostream(&file);
                    const surface: [*]c.SDL_Surface = try util.sdl_call(c.IMG_Load_IO(
                        @ptrCast(sdl_io),
                        true,
                    ));

                    try self.images.put(App.gpa(), full_name, surface);
                    if (!std.meta.eql(self.get_size(0), self.get_size(self.images.count() - 1))) {
                        logger.warn("{s}: image resolution mismatch", .{full_name});
                        _ = self.images.pop();
                        c.SDL_DestroySurface(surface);
                    }
                },
                else => continue,
            }
        }
    }

    fn concat(prefix: []const []const u8, name: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(App.gpa());
        var w = buf.writer(App.gpa());

        for (prefix) |s| try w.print(".{s}", .{s});
        try w.print(".{s}", .{name});
        const str = try App.static_alloc().dupeZ(u8, buf.items);
        return str;
    }

    fn deinit(self: *Builder) void {
        self.prefix.deinit(App.gpa());
        for (self.images.values()) |surf| {
            c.SDL_DestroySurface(surf);
        }
        self.images.deinit(App.gpa());
    }
};

fn generate_missing(self: *TextureAtlas) !void {
    const pixels = try App.gpa().alloc(u8, 2 * self.img_width * self.img_height);
    defer App.gpa().free(pixels);
    @memset(pixels, 0xFF);

    const a_offset = 0;
    const b_offset = self.img_width * self.img_height / 2 + self.img_width / 2;
    const stride = self.img_width;

    for (0..self.img_height / 2) |j| {
        for (0..self.img_width / 2) |i| {
            const a = a_offset + j * stride + i;
            const b = b_offset + j * stride + i;
            pixels[2 * a] = 0;
            pixels[2 * a + 1] = 0;
            pixels[2 * b] = 0;
            pixels[2 * b + 1] = 0;
        }
    }

    try gl_call(gl.TexSubImage3D(
        gl.TEXTURE_2D_ARRAY,
        0, // level
        0, // xoffset
        0, // yoffset
        @intCast(self.images.count()), // zoffset
        @intCast(self.img_width), // width
        @intCast(self.img_height), // height
        1, // depth
        gl.RG,
        gl.UNSIGNED_BYTE,
        @ptrCast(pixels),
    ));
    logger.info("registered missing texture", .{});
}
