const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("server/main.zig"),
        }),
    });
    b.installArtifact(server);

    const options = b.addOptions();
    options.addOption(bool, "ecs_logging", b.option(bool, "ecs_logging", "Enable logging in the ecs") orelse true);
    server.root_module.addOptions("Options", options);

    const gl = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.6",
    });
    const client = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("client/main.zig"),
            .link_libc = true,
        }),
    });
    b.installArtifact(client);
    client.root_module.linkSystemLibrary("SDL3", .{});
    client.root_module.addImport("gl", gl);

    const run_step = b.step("run", "run the client");
    const run_client = b.addRunArtifact(client);
    run_step.dependOn(&run_client.step);
    if (b.args) |args| {
        run_client.addArgs(args);
    }

    const test_step = b.step("test", "run all tests");
    inline for (.{ server.root_module, client.root_module }) |mod| {
        const test_artifact = b.addTest(.{ .root_module = mod });
        b.installArtifact(test_artifact);
        const run_tests = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_tests.step);
    }
}
