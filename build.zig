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
    const lib_options = b.addOptions();
    lib_options.addOption(bool, "ecs_logging", b.option(bool, "ecs_logging", "Enable logging in the ecs") orelse false);
    lib_options.addOption(bool, "ecs_typecheck", b.option(bool, "ecs_typecheck", "Enable runtime type checking in the ecs") orelse true);
    lib.root_module.addOptions("Options", lib_options);

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
    client.root_module.addImport("Block", b.createModule(.{
        .root_source_file = b.path("assets/Block.zon"),
    }));
    b.installArtifact(client);
    const client_options = b.addOptions();
    client_options.addOption(bool, "chunk_debug_buffer", b.option(bool, "chunk_debug_buffer", "Enable debug buffer in the chunk shader") orelse false);
    client_options.addOption(bool, "gpu_alloc_log", b.option(bool, "gpu_alloc_log", "Enable GpuAlloc logging") orelse false);
    client_options.addOption(bool, "gl_debug", b.option(bool, "gl_debug", "Enable OpenGL debug context") orelse true);
    client_options.addOption(bool, "gl_check_errors", b.option(bool, "gl_check_errors", "Check gl_Error") orelse true);
    client_options.addOption(bool, "greedy_meshing", b.option(bool, "greedy_meshing", "Use greedy meshing") orelse true);
    client.root_module.addOptions("ClientOptions", client_options);

    const run_client = if (b.option(bool, "mangohud", "Enable mangohud") orelse true) blk: {
        const cmd = b.addSystemCommand(&.{"mangohud"});
        cmd.addFileArg(client.getEmittedBin());
        break :blk cmd;
    } else b.addRunArtifact(client);

    const run_step = b.step("run", "run the client");
    run_step.dependOn(b.getInstallStep());
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
