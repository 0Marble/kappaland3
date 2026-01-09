const App = @import("App.zig");
const glTF = @import("assets/glTF.zig");
const std = @import("std");
const zm = @import("zm");
const ModelRenderer = @This();
const Camera = @import("Camera.zig");
const logger = std.log.scoped(.model_renderer);

pub fn draw(cam: *Camera) !void {
    for (App.assets().get_models().gltfs.values()) |model| {
        try model.draw(cam);
    }
}

pub const Model = struct {
    ref: *glTF,
    id: glTF.InstanceId,

    pub fn instantiate(name: []const u8) !Model {
        const gltf = App.assets().get_models().get(name) orelse {
            logger.err("{s}: no such model", .{name});
            return error.ModelNotFound;
        };

        return .{
            .ref = gltf,
            .id = try gltf.add_instance(),
        };
    }

    pub fn kill(self: Model) void {
        self.ref.remove_instance(self.id);
    }

    pub fn set_transform(self: Model, transform: zm.Mat4f) !void {
        self.ref.set_transform(self.id, transform);
    }
};
