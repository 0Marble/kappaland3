const std = @import("std");
const gl = @import("gl");
const util = @import("../util.zig");
const gl_call = @import("../util.zig").gl_call;
const sdl_call = @import("../util.zig").sdl_call;
const Assets = @import("../Assets.zig");
const c = @import("../c.zig").c;
const VFS = @import("VFS.zig");

const logger = std.log.scoped(.texture_atlas);

handle: gl.uint,
images: std.StringArrayHashMapUnmanaged(void),
arena: std.heap.ArenaAllocator,
img_width: usize,
img_height: usize,

const TextureAtlas = @This();
pub fn init(gpa: std.mem.Allocator, dir: *VFS.Dir) !TextureAtlas {
    const prefix: []const u8 = if (dir.parent) |p| p.path else "";
    logger.info("loading atlas {s}", .{dir.path});

    var ok = true;

    var temp = std.heap.ArenaAllocator.init(gpa);
    defer temp.deinit();

    var surfaces = std.ArrayList(FileAndSurface).empty;
    defer surfaces.deinit(temp.allocator());
    _ = dir.visit_no_fail(find_textures, .{ &surfaces, temp.allocator(), &ok });

    var self = TextureAtlas{
        .handle = 0,
        .images = .empty,
        .arena = .init(gpa),
        .img_height = @intCast(surfaces.items[0][1].h),
        .img_width = @intCast(surfaces.items[0][1].w),
    };
    try self.images.ensureTotalCapacity(self.arena.allocator(), surfaces.items.len + 1);

    logger.info("atlas size: {d}x{d}x{d}", .{ surfaces.items.len + 1, self.img_width, self.img_height });

    try gl_call(gl.GenTextures(1, @ptrCast(&self.handle)));
    try gl_call(gl.BindTexture(gl.TEXTURE_2D_ARRAY, self.handle));
    try gl_call(gl.TexStorage3D(
        gl.TEXTURE_2D_ARRAY,
        1,
        gl.RGB8,
        @intCast(self.img_width),
        @intCast(self.img_height),
        @intCast(surfaces.items.len + 1),
    ));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE));
    try gl_call(gl.TexParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE));

    try self.generate_missing();
    for (surfaces.items) |kv| {
        const file, const surface = kv;
        defer c.SDL_DestroySurface(surface);

        try sdl_call(c.SDL_LockSurface(surface));
        defer _ = c.SDL_LockSurface(surface);

        const pixels: []const u8 = @ptrCast(surface.pixels);

        const fmt: gl.@"enum", const typ: gl.@"enum" = switch (surface.format) {
            c.SDL_PIXELFORMAT_RGBA32 => .{ gl.RGBA, gl.UNSIGNED_BYTE },
            else => {
                logger.warn("{s}: unsupported pixel format: {d}", .{ file.path, surface.format });
                ok = false;
                continue;
            },
        };

        const sub_path = file.path[prefix.len..];
        const name = try Assets.to_name(self.arena.allocator(), sub_path);

        const idx = self.images.count();
        try gl_call(gl.TexSubImage3D(
            gl.TEXTURE_2D_ARRAY,
            0, // level
            0, // xoffset
            0, // yoffset
            @intCast(idx), // zoffset
            @intCast(surface.w), // width
            @intCast(surface.h), // height
            1, // depth
            fmt,
            typ,
            @ptrCast(pixels),
        ));

        self.images.putAssumeCapacity(name, {});
        logger.info("registered texture {s}@{d}", .{ name, idx });
    }

    if (!ok) {
        logger.warn("atlas {s}: had errors", .{dir.path});
    } else {
        logger.info("atlas {s}: all ok!", .{dir.path});
    }

    return self;
}

pub fn deinit(self: *TextureAtlas) void {
    gl.DeleteTextures(1, @ptrCast(&self.handle));
    self.arena.deinit();
}

pub fn get_idx(self: *TextureAtlas, name: []const u8) usize {
    return self.images.getIndex(name) orelse self.get_missing();
}

pub fn get_idx_or_warn(self: *TextureAtlas, name: []const u8) usize {
    return self.images.getIndex(name) orelse {
        logger.warn("missing texture: '{s}'", .{name});
        return self.get_missing();
    };
}

pub fn get_missing(self: *TextureAtlas) usize {
    _ = self;
    return 0;
}

const FileAndSurface = struct { *VFS.File, *c.SDL_Surface };
fn find_textures(
    list: *std.ArrayList(FileAndSurface),
    arena: std.mem.Allocator,
    all_ok: *bool,
    file: *VFS.File,
) !void {
    errdefer all_ok.* = false;

    const contents = (try file.read_all(arena)).src;
    const io: *c.SDL_IOStream = try sdl_call(c.SDL_IOFromConstMem(@ptrCast(contents), contents.len));

    const allowed_formats = .{ .PNG, .JPG, .BMP };
    var ok = false;
    inline for (allowed_formats) |fmt| {
        const fn_name = "IMG_is" ++ @tagName(fmt);
        const fptr = @field(c, fn_name);
        if (ok or @call(.auto, fptr, .{io})) {
            ok = true;
        }
    }
    if (!ok) return;

    const surface: *c.SDL_Surface = @ptrCast(try sdl_call(c.IMG_Load_IO(io, false)));
    if (list.getLastOrNull()) |prev| {
        if (prev[1].w != surface.w or prev[1].h != surface.h) {
            all_ok.* = false;
            logger.warn("{s}: inconsistant size for this atlas, skipping", .{file.path});
            try sdl_call(c.SDL_DestroySurface(surface));
            return;
        }
    }

    try list.append(arena, .{ file, surface });
}

fn generate_missing(self: *TextureAtlas) !void {
    const pixels = try self.arena.allocator().alloc(u8, 2 * self.img_width * self.img_height);
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

    const idx = self.images.count();
    try gl_call(gl.TexSubImage3D(
        gl.TEXTURE_2D_ARRAY,
        0, // level
        0, // xoffset
        0, // yoffset
        @intCast(idx), // zoffset
        @intCast(self.img_width), // width
        @intCast(self.img_height), // height
        1, // depth
        gl.RG,
        gl.UNSIGNED_BYTE,
        @ptrCast(pixels),
    ));
    self.images.putAssumeCapacity("missing", {});
    logger.info("registered missing texture@{d}", .{idx});
}
