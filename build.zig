const std = @import("std");

fn build_imgui(
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
        .file = b.path("wrapper/cimgui_impl.cpp"),
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
    lib.installHeader(b.path("wrapper/cimgui_impl.h"), "cimgui_impl.h");
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

fn artifact_options(b: *std.Build, comptime opts: anytype) *std.Build.Step.Options {
    const opts_map = b.addOptions();

    inline for (opts) |o| {
        const t = switch (o.type) {
            .bool => bool,
            .usize => usize,
            .str => []const u8,
            else => @compileError("Unsupported option type " ++ @tagName(o.type)),
        };
        opts_map.addOption(t, o.name, b.option(t, o.name, o.desc) orelse o.default);
    }

    return opts_map;
}

fn build_client(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const libmine = b.modules.get("mine").?;

    const imgui = build_imgui(b, target, optimize);
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
    client.root_module.linkSystemLibrary("SDL3_image", .{});
    client.root_module.addImport("gl", gl);
    client.root_module.addImport("zm", zm.module("zm"));
    client.root_module.addImport("libmine", libmine);
    client.root_module.addImport("SettingsMenu", b.createModule(.{
        .root_source_file = b.path("assets/SettingsMenu.zon"),
    }));
    client.root_module.linkLibrary(imgui);
    b.installArtifact(client);

    const wrapper: ?[]const u8 = b.option([]const u8, "command", "Wrapper command");
    const run_client = if (wrapper) |command| blk: {
        if (std.mem.eql(u8, command, "gdb")) {
            const cmd = b.addSystemCommand(&.{command});
            client.use_llvm = true;
            cmd.addArg("--args");
            cmd.addFileArg(client.getEmittedBin());
            break :blk cmd;
        } else if (std.mem.eql(u8, command, "perf")) {
            const perf_run = b.addSystemCommand(&.{command});
            perf_run.addArgs(&.{ "record", "-F", "99", "-g" });
            perf_run.addFileArg(client.getEmittedBin());

            const draw_flame = b.addSystemCommand(&.{"perf"});
            draw_flame.addArgs(&.{ "script", "report", "flamegraph" });
            draw_flame.step.dependOn(&perf_run.step);

            const open_chrome = b.addSystemCommand(&.{"chromium-browser"});
            open_chrome.addArg("flamegraph.html");
            open_chrome.step.dependOn(&draw_flame.step);

            break :blk open_chrome;
        } else {
            const cmd = b.addSystemCommand(&.{command});
            cmd.addFileArg(client.getEmittedBin());
            break :blk cmd;
        }
    } else b.addRunArtifact(client);

    const run_step = b.step("run", "run the client");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_client.step);
    if (b.args) |args| {
        run_client.addArgs(args);
    }

    return client.root_module;
}

fn build_libmine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const libmine = b.addModule("mine", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("lib/root.zig"),
    });

    return libmine;
}

fn build_server(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const libmine = b.modules.get("mine").?;
    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("server/main.zig"),
        }),
    });
    server.root_module.addImport("libmine", libmine);
    b.installArtifact(server);

    const run_server = b.addRunArtifact(server);
    const run_step = b.step("serve", "run the server");
    run_step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_server.step);
    if (b.args) |args| {
        run_server.addArgs(args);
    }

    return server.root_module;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = artifact_options(b, @import("./Build.zon"));

    const libmine = build_libmine(b, target, optimize);
    const client = build_client(b, target, optimize);
    const server = build_server(b, target, optimize);

    const test_step = b.step("test", "run all tests");
    const llvm = b.option(bool, "llvm", "Use llvm") orelse false;

    inline for (.{ server, client, libmine }) |mod| {
        mod.addOptions("Build", options);

        const test_artifact = b.addTest(.{ .root_module = mod });
        test_artifact.use_llvm = llvm;
        const run_tests = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_tests.step);

        b.installArtifact(test_artifact);
    }
}
