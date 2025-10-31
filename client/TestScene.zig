const App = @import("App.zig");
const std = @import("std");
const Shader = @import("Shader.zig");
const Mesh = @import("Mesh.zig");
const Scene = @import("HelloScene");
const gl_call = @import("util.zig").gl_call;
const gl = @import("gl");
const zm = @import("zm");

mesh: [Scene.objects.len]Mesh,
mat: [Scene.objects.len]zm.Mat4f,
shader: Shader,

const Vert = struct {
    pos: struct { x: f32, y: f32, z: f32 },
    norm: struct { x: f32, y: f32, z: f32 },

    pub fn setup_attribs() !void {
        inline for (.{ "pos", "norm" }, 0..) |field, i| {
            const Attrib = @FieldType(@This(), field);
            try gl_call(gl.VertexAttribPointer(
                i,
                @intCast(std.meta.fields(Attrib).len),
                gl.FLOAT,
                gl.FALSE,
                @sizeOf(@This()),
                @offsetOf(@This(), field),
            ));
            try gl_call(gl.EnableVertexAttribArray(i));
        }
    }
};

const Self = @This();
pub fn init() !Self {
    var sources = [2]Shader.Source{
        Shader.Source{
            .sources = &.{Scene.vert},
            .kind = gl.VERTEX_SHADER,
            .name = "vert",
        },
        Shader.Source{
            .sources = &.{Scene.frag},
            .kind = gl.FRAGMENT_SHADER,
            .name = "frag",
        },
    };

    var self: Self = .{
        .mesh = undefined,
        .shader = try .init(&sources),
        .mat = undefined,
    };

    inline for (Scene.objects, 0..) |obj, i| {
        const x, const y, const z, const w = obj.transform.rotation;
        const quat = zm.Quaternionf.init(x, y, z, w);
        self.mat[i] = zm.Mat4f.translationVec3(obj.transform.translation)
            .multiply(zm.Mat4f.fromQuaternion(quat)
            .multiply(zm.Mat4f.scalingVec3(obj.transform.scale)));

        const verts = comptime blk: {
            var verts = std.mem.zeroes([obj.verts.len]Vert);
            for (obj.verts, 0..) |v, j| {
                verts[j].pos = .{ .x = v.pos.x, .y = v.pos.y, .z = v.pos.z };
                verts[j].norm = .{ .x = v.norm.x, .y = v.norm.y, .z = v.norm.z };
            }
            break :blk verts;
        };
        self.mesh[i] = try .init(Vert, u16, &verts, &obj.inds, gl.STATIC_DRAW);
    }

    inline for (comptime std.meta.fieldNames(@TypeOf(Scene.uniforms))) |uniform| {
        const data = @field(Scene.uniforms, uniform);
        const kind = @field(Scene.uniform_types, uniform);
        try self.shader.set(uniform, data, kind);
    }

    return self;
}

pub fn draw(self: *Self, vp_matrix: zm.Mat4f) !void {
    try self.shader.bind();
    inline for (Scene.objects, 0..) |obj, i| {
        inline for (comptime std.meta.fieldNames(@TypeOf(obj.material))) |uniform| {
            const data = @field(obj.material, uniform);
            const kind = @field(Scene.uniform_types, uniform);
            try self.shader.set(uniform, data, kind);
        }
        const mvp = vp_matrix.multiply(self.mat[i]);
        try self.shader.set_mat4("u_mvp", mvp);
        try self.shader.set_mat4("u_model", self.mat[i]);
        try self.shader.set_mat4("u_transp_inv_model", self.mat[i].inverse().transpose());
        try self.mesh[i].draw(gl.TRIANGLES);
    }
}

pub fn deinit(self: *Self) void {
    self.shader.deinit();
    for (&self.mesh) |*m| m.deinit();
}
