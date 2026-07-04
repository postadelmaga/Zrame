const std = @import("std");

/// Wayland protocol XMLs whose glue we generate at build time with `wayland-scanner`.
/// Core `wl_*` interfaces live in libwayland-client itself; everything else needs its
/// interface tables compiled into the binary (`private-code`).
const protocol_xmls = [_][]const u8{
    "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    "/usr/share/wayland-protocols/staging/ext-background-effect/ext-background-effect-v1.xml",
    "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml",
    // cursor-shape references zwp_tablet_tool_v2, so its tables must exist too.
    "/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml",
    // GPU frames land in the video subsurface as dmabufs (zero-copy path).
    "/usr/share/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml",
    // KDE global menu: link the toplevel to a com.canonical.dbusmenu address.
    "/usr/share/qt6/wayland/protocols/appmenu/appmenu.xml",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Everything zrame draws is per-pixel software rendering; Debug builds can't hold
    // 60 Hz on the demos, so optimized is the default (-Doptimize=Debug to override).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    const zicro = b.dependency("zicro", .{ .target = target, .optimize = optimize });

    // The zrame library module: the window/frame layer of the Frame architecture.
    const zrame = b.addModule("zrame", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zicro", .module = zicro.module("zicro") },
        },
    });
    zrame.linkSystemLibrary("wayland-client", .{});
    // Tray icon (StatusNotifierItem) talks to the session bus through sd-bus. We
    // hand-declare the FFI, so no headers are needed — just link libsystemd.
    zrame.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });

    for (protocol_xmls) |xml| {
        const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        scan.addFileArg(.{ .cwd_relative = xml });
        const c_file = scan.addOutputFileArg("protocol.c");
        zrame.addCSourceFile(.{ .file = c_file });
    }

    // `zig build test` — every `test` block in the library.
    const mod_tests = b.addTest(.{ .root_module = zrame });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Examples: `zig build run-hello`, `zig build run-frames`.
    inline for (.{ "hello", "frames", "scroll", "tray", "menu" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zrame", .module = zrame },
                    .{ .name = "zicro", .module = zicro.module("zicro") },
                },
            }),
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
        run_step.dependOn(&run_cmd.step);
    }

    // A loadable plugin built as a shared library, plus a host that dlopens it:
    // `zig build run-plugin`. The plugin is a normal Zig object against the zrame module.
    const clock = b.addLibrary(.{
        .name = "zrame_clock",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/plugin_clock.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrame", .module = zrame }},
        }),
    });
    b.installArtifact(clock);

    const host_exe = b.addExecutable(.{
        .name = "plugin_host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/plugin_host.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zrame", .module = zrame }},
        }),
    });
    b.installArtifact(host_exe);
    const host_run = b.addRunArtifact(host_exe);
    // The host dlopens zig-out/lib/libzrame_clock.so, so make sure it's installed first.
    host_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| host_run.addArgs(args);
    const host_step = b.step("run-plugin", "Run the dlopen plugin host example");
    host_step.dependOn(&host_run.step);
}
