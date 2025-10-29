const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/server_main.zig"),
        }),
    });
    b.installArtifact(server);

    const options = b.addOptions();
    options.addOption(bool, "ecs_logging", b.option(bool, "ecs_logging", "Enable logging in the ecs") orelse true);
    server.root_module.addOptions("Options", options);

    const run_step = b.step("run", "run the server");
    const run_server = b.addRunArtifact(server);
    run_step.dependOn(&run_server.step);
    if (b.args) |args| {
        run_server.addArgs(args);
    }

    const test_step = b.step("test", "run all tests");
    const test_artifact = b.addTest(.{ .root_module = server.root_module });
    b.installArtifact(test_artifact);
    const run_tests = b.addRunArtifact(test_artifact);
    test_step.dependOn(&run_tests.step);
}
