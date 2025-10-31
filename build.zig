const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "mine",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("lib/root.zig"),
        }),
    });
    b.installArtifact(lib);
    const options = b.addOptions();
    options.addOption(bool, "ecs_logging", b.option(bool, "ecs_logging", "Enable logging in the ecs") orelse false);
    options.addOption(bool, "ecs_typecheck", b.option(bool, "ecs_typecheck", "Enable runtime type checking in the ecs") orelse true);
    lib.root_module.addOptions("Options", options);

    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("server/main.zig"),
        }),
    });
    server.root_module.addImport("libmine", lib.root_module);
    b.installArtifact(server);

    const gl = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .profile = .core,
        .version = .@"4.6",
    });
    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
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
    if (b.option(bool, "llvm", "Build with llvm") orelse false) {
        client.use_llvm = true;
    }
    client.root_module.linkSystemLibrary("SDL3", .{});
    client.root_module.addImport("gl", gl);
    client.root_module.addImport("zm", zm.module("zm"));
    client.root_module.addImport("libmine", lib.root_module);
    client.root_module.addImport("HelloScene", b.createModule(.{
        .root_source_file = b.path("assets/HelloScene.zon"),
    }));
    b.installArtifact(client);

    const run_step = b.step("run", "run the client");
    const run_client = b.addRunArtifact(client);
    run_step.dependOn(&run_client.step);
    if (b.args) |args| {
        run_client.addArgs(args);
    }

    const test_step = b.step("test", "run all tests");
    inline for (.{ server.root_module, client.root_module, lib.root_module }) |mod| {
        const test_artifact = b.addTest(.{ .root_module = mod });
        const run_tests = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_tests.step);
    }
}
