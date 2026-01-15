const std = @import("std");

const Imgui = struct {
    artifact: *std.Build.Step.Compile,

    fn build(
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) Imgui {
        const imgui = b.dependency("imgui", .{});
        const cimgui = b.dependency("cimgui", .{});

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
            .linkage = .static,
        });
        lib.installHeader(cimgui.path("cimgui.h"), "cimgui.h");
        lib.installHeader(b.path("wrapper/cimgui_impl.h"), "cimgui_impl.h");
        lib.linkLibC();
        lib.linkLibCpp();

        return .{ .artifact = lib };
    }

    fn link(self: Imgui, b: *std.Build, compile: *std.Build.Step.Compile) void {
        compile.linkLibrary(self.artifact);
        _ = b;
    }
};

fn compute_build_id(b: *std.Build) [:0]const u8 {
    const paths: []const []const u8 = &.{
        "client/",
        "server/",
        "lib/",
        "build/",
        "build.zig",
        "build.zig.zon",
        "assets/",
    };

    const Static = struct {
        var buf = std.mem.zeroes([256]u8);
    };

    var hasher = std.hash.Crc32.init();
    for (paths) |path| {
        const stat = b.build_root.handle.statFile(path) catch unreachable;
        hasher.update(std.mem.asBytes(&stat.atime));
    }
    return std.fmt.bufPrintZ(&Static.buf, "{x}", .{hasher.final()}) catch unreachable;
}

fn generate_builtins(b: *std.Build) *std.Build.Module {
    const builtins = b.addWriteFile("main.zig",
        \\pub const Options = @import("Options");
        \\pub const Assets = @import("Assets.zig");
    );
    const mod = b.createModule(.{
        .root_source_file = builtins.getDirectory().path(b, "main.zig"),
    });

    const opts_map = b.addOptions();
    const opts = @import("build/Options.zon");

    var assets_dir: ?[]const u8 = null;
    inline for (opts) |o| {
        const t = switch (o.type) {
            .bool => bool,
            .usize => usize,
            .str => []const u8,
            else => @compileError("Unsupported option type " ++ @tagName(o.type)),
        };
        const val = b.option(t, o.name, o.desc) orelse o.default;
        if (comptime std.mem.eql(u8, "assets_dir", o.name)) assets_dir = val;
        opts_map.addOption(t, o.name, val);
    }
    opts_map.addOption([:0]const u8, "build_id", compute_build_id(b));

    mod.addImport("Options", opts_map.createModule());

    const builtin_assets = @import("build/BuiltinAssets.zon");
    const assets_src = comptime blk: {
        var src: [:0]const u8 = "";
        for (builtin_assets) |asset_path| {
            src = src ++ std.fmt.comptimePrint(
                "pub const @\"{s}\" = @embedFile(\"{s}\");\n",
                .{ asset_path, asset_path },
            );
        }
        break :blk src;
    };
    _ = builtins.add("Assets.zig", assets_src);

    inline for (builtin_assets) |asset_path| {
        const path = b.path(assets_dir orelse "assets/").path(b, asset_path);
        path.addStepDependencies(&builtins.step);
        _ = builtins.addCopyFile(path, asset_path);
    }

    const builtin_assets_path = b.path("build/BuiltinAssets.zon");
    builtin_assets_path.addStepDependencies(&builtins.step);
    const options_path = b.path("build/Options.zon");
    options_path.addStepDependencies(&builtins.step);

    return mod;
}

fn build_client(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const libmine = b.modules.get("mine").?;

    const imgui = Imgui.build(b, target, optimize);
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
    imgui.link(b, client);

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

    const build_mod = generate_builtins(b);
    b.installDirectory(.{
        .source_dir = b.path("assets/"),
        .install_dir = .bin,
        .install_subdir = "assets/",
    });

    const libmine = build_libmine(b, target, optimize);
    const client = build_client(b, target, optimize);
    const server = build_server(b, target, optimize);

    const test_step = b.step("test", "run all tests");
    const llvm = b.option(bool, "llvm", "Use llvm") orelse false;

    inline for (.{ server, client, libmine }) |mod| {
        mod.addImport("Build", build_mod);

        const test_artifact = b.addTest(.{ .root_module = mod });
        test_artifact.use_llvm = llvm;
        const run_tests = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_tests.step);

        b.installArtifact(test_artifact);
    }
}
