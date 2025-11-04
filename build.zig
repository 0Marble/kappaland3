const std = @import("std");

fn get_imgui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const imgui = b.dependency("imgui", .{});
    const cimgui = b.dependency("cimgui", .{});
    const imgui_files: []const []const u8 = &.{
        "imgui.cpp",
        "imgui_demo.cpp",
        "imgui_draw.cpp",
        "imgui_tables.cpp",
        "imgui_widgets.cpp",
        "backends/imgui_impl_sdl3.cpp",
        "backends/imgui_impl_opengl3.cpp",
    };
    const flags: []const []const u8 = &.{
        "-fPIC",
        "-g",
        "-Wall",
        "-Wformat",
        "-DCIMGUI_USE_OPENGL3",
        "-DCIMGUI_USE_SDL3",
    };
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFiles(.{
        .language = .cpp,
        .root = imgui.path("."),
        .files = imgui_files,
        .flags = flags,
    });
    mod.addCSourceFiles(.{
        .language = .cpp,
        .root = cimgui.path("."),
        .files = &.{"cimgui2.cpp"},
        .flags = flags,
    });
    mod.addCSourceFile(.{
        .language = .cpp,
        .file = b.path("client/cimgui_impl.cpp"),
        .flags = flags,
    });

    mod.addIncludePath(imgui.path("."));
    mod.addIncludePath(cimgui.path("."));
    mod.linkSystemLibrary("GL", .{});
    mod.linkSystemLibrary("SDL3", .{});
    const lib = b.addLibrary(.{
        .name = "cimgui",
        .root_module = mod,
        .linkage = .dynamic,
    });
    lib.installHeader(cimgui.path("cimgui.h"), "cimgui.h");
    lib.installHeader(b.path("client/cimgui_impl.h"), "cimgui_impl.h");
    lib.linkLibC();
    lib.linkLibCpp();

    const cp_cmd = b.addSystemCommand(&.{"cp"});
    cp_cmd.addFileArg(cimgui.path("cimgui.cpp"));
    cp_cmd.addFileArg(cimgui.path("cimgui2.cpp"));
    const sed_cmd = b.addSystemCommand(&.{
        "sed",
        "-i",
        \\7c#include <imgui.h>
        \\8c#include <imgui_internal.h>
        ,
    });
    sed_cmd.addFileArg(cimgui.path("cimgui2.cpp"));

    const install = b.addInstallArtifact(lib, .{});
    sed_cmd.step.dependOn(&cp_cmd.step);
    install.step.dependOn(&sed_cmd.step);
    b.getInstallStep().dependOn(&install.step);

    return install.artifact;
}

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

    const imgui = get_imgui(b, target, optimize);
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
    client.root_module.linkLibrary(imgui);
    b.installArtifact(client);
    const client_options = b.addOptions();
    client_options.addOption(bool, "gpu_alloc_log", b.option(bool, "gpu_alloc_log", "Enable GpuAlloc logging") orelse false);
    client_options.addOption(bool, "gl_debug", b.option(bool, "gl_debug", "Enable OpenGL debug context") orelse true);
    client_options.addOption(bool, "gl_check_errors", b.option(bool, "gl_check_errors", "Check gl_Error") orelse true);
    client_options.addOption(bool, "greedy_meshing", b.option(bool, "greedy_meshing", "Use greedy meshing") orelse true);
    client_options.addOption(usize, "world_size", b.option(usize, "world_size", "World size in chunks (x/z)") orelse 16);
    client_options.addOption(usize, "world_height", b.option(usize, "world_height", "World height in chunks") orelse 8);
    client_options.addOption(bool, "ui_store_src", b.option(bool, "ui_store_src", "Store callback source locations in DebugUi") orelse true);
    client.root_module.addOptions("ClientOptions", client_options);

    const wrapper: ?[]const u8 = b.option([]const u8, "command", "Wrapper command");
    const run_client = if (wrapper) |command| blk: {
        const cmd = b.addSystemCommand(&.{command});
        if (std.mem.eql(u8, command, "gdb")) {
            client.use_llvm = true;
            client_options.addOption(bool, "in_gdb", true);
            cmd.addArg("--args");
        }
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
