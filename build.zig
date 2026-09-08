const std = @import("std");
const builtin = @import("builtin");

fn pkgConfigExists(b: *std.Build, name: []const u8) bool {
    return switch (b.runFallible(&.{ "pkg-config", "--exists", name }, .{
        .stderr_behavior = .ignore,
    })) {
        .success => true,
        else => false,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zx (ziex) with SQLite — used by Spell/Sqlite.zig. `app_opts` is required by
    // zx.App even though we only consume zx.Db from the library.
    const ziex_dep = b.dependency("ziex", .{
        .target = target,
        .optimize = optimize,
        .@"exclude-core-lang" = true,
        .@"feature-sqlite" = true,
    });
    const zx_mod = ziex_dep.module("zx");
    {
        const app_opts = b.addOptions();
        app_opts.addOption(?[]const u8, "app_base_path", null);
        app_opts.addOption(?u16, "server_port", null);
        app_opts.addOption(?[]const u8, "server_address", null);
        app_opts.addOption([]const u8, "cli_command", "--");
        app_opts.addOption(bool, "introspect", false);
        app_opts.addOption(bool, "feat_sqlite_server", false);
        app_opts.addOption(bool, "feat_pg_server", false);
        app_opts.addOption(bool, "feat_kv_server", false);
        app_opts.addOption(bool, "feat_kv_client", false);
        app_opts.addOption(bool, "feat_cache_server", false);
        zx_mod.addOptions("app_opts", app_opts);
    }

    // Tokenizer-only module (no FFI / libc) for wasm-friendly consumers like webz.
    const tokenization_mod = b.addModule("tokenization", .{
        .root_source_file = b.path("src/tokenization/tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spell_mod = b.addModule("spell", .{
        .root_source_file = b.path("src/Spell.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tokenization", .module = tokenization_mod },
        },
    });

    const autocomplete_mod = b.addModule("autocomplete", .{
        .root_source_file = b.path("src/AutoComplete.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("byakaron", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // The C-ABI FFI layer (src/ffi/ffi.zig) uses std.heap.c_allocator so
        // strings can be freed across the FFI boundary; that needs libc.
        .link_libc = true,
        .imports = &.{
            .{ .name = "zx", .module = zx_mod },
            .{ .name = "tokenization", .module = tokenization_mod },
            .{ .name = "spell", .module = spell_mod },
            .{ .name = "autocomplete", .module = autocomplete_mod },
        },
    });

    // Static lib (macOS Xcode links extracted objects). Shared lib (Windows C#
    // P/Invoke loads byakaron.dll). `-Dshared` selects dynamic linkage.
    const shared = b.option(bool, "shared", "Build shared library (DLL/dylib/so) for FFI") orelse false;
    {
        const lib = b.addLibrary(.{
            .linkage = if (shared) .dynamic else .static,
            .name = "byakaron",
            .root_module = mod,
        });
        // Install the FFI header alongside the lib so consumers can find it.
        lib.installHeader(b.path("src/ffi/byakaron.h"), "byakaron.h");
        b.installArtifact(lib);
    }

    // Linux IBus input method — C engine over the FFI, linked against system IBus.
    if (builtin.os.tag == .linux) {
        // Its own static copy of the core rather than the artifact above, so
        // `zig build linux` produces a self-contained binary whether or not
        // -Dshared was passed (the .so is for the GTK app and packaging).
        const ime_core = b.addLibrary(.{
            .linkage = .static,
            .name = "byakaron_ime_core",
            .root_module = mod,
        });

        const ime = b.addExecutable(.{
            .name = "byakaron-ibus",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        ime.root_module.addCSourceFiles(.{
            .files = &.{
                "platforms/linux/Keyboard/main.c",
                "platforms/linux/Keyboard/engine.c",
                "platforms/linux/Core/transliterator.c",
                "platforms/linux/Core/autocomplete.c",
                "platforms/linux/Core/spell.c",
                "platforms/linux/Core/composer.c",
            },
            .flags = &.{ "-std=gnu11", "-Wall", "-Wextra" },
        });
        ime.root_module.addIncludePath(b.path("src/ffi"));
        ime.root_module.addIncludePath(b.path("platforms/linux/Core"));
        ime.root_module.addIncludePath(b.path("platforms/linux/Keyboard"));
        // Resolved through pkg-config; see platforms/linux/scripts/setup_deps.sh.
        ime.root_module.linkSystemLibrary("ibus-1.0", .{});
        ime.root_module.linkSystemLibrary("glib-2.0", .{});
        ime.root_module.linkSystemLibrary("gobject-2.0", .{});
        ime.root_module.linkLibrary(ime_core);

        const install_ime = b.addInstallArtifact(ime, .{});
        const linux_step = b.step("linux", "Build the Linux IBus engine (byakaron-ibus)");
        linux_step.dependOn(&install_ime.step);

        // Integration test: drives the engine through a private IBus input
        // context, so it needs a daemon with the engine registered (dev_run.sh).
        const ime_test = b.addExecutable(.{
            .name = "byakaron-ime-test",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        ime_test.root_module.addCSourceFiles(.{
            .files = &.{"platforms/linux/tests/ime_test.c"},
            .flags = &.{ "-std=gnu11", "-Wall", "-Wextra" },
        });
        ime_test.root_module.linkSystemLibrary("ibus-1.0", .{});
        ime_test.root_module.linkSystemLibrary("glib-2.0", .{});
        ime_test.root_module.linkSystemLibrary("gobject-2.0", .{});

        const install_ime_test = b.addInstallArtifact(ime_test, .{});
        const linux_test_step = b.step("linux-test", "Build the Linux IME integration test");
        linux_test_step.dependOn(&install_ime_test.step);

        // GTK4 + libadwaita companion app. A separate step from `linux` on
        // purpose: the engine must stay buildable on a box with only
        // libibus-dev, and this needs libgtk-4-dev and libadwaita-1-dev too.
        const app_core = b.addLibrary(.{
            .linkage = .static,
            .name = "byakaron_app_core",
            .root_module = mod,
        });

        const app = b.addExecutable(.{
            .name = "byakaron",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        app.root_module.addCSourceFiles(.{
            .files = &.{
                "platforms/linux/App/main.c",
                "platforms/linux/App/window.c",
                "platforms/linux/App/typing.c",
                "platforms/linux/App/spelling.c",
                "platforms/linux/App/layout.c",
                "platforms/linux/App/setup.c",
                "platforms/linux/Core/transliterator.c",
                "platforms/linux/Core/autocomplete.c",
                "platforms/linux/Core/spell.c",
            },
            .flags = &.{ "-std=gnu11", "-Wall", "-Wextra" },
        });
        app.root_module.addIncludePath(b.path("src/ffi"));
        app.root_module.addIncludePath(b.path("platforms/linux/Core"));
        app.root_module.addIncludePath(b.path("platforms/linux/App"));
        app.root_module.linkSystemLibrary("gtk4", .{});
        app.root_module.linkSystemLibrary("libadwaita-1", .{});
        app.root_module.linkSystemLibrary("glib-2.0", .{});
        app.root_module.linkSystemLibrary("gobject-2.0", .{});
        // Its own static copy of the core, like the engine above: two 7 MB
        // binaries beat one shared .so that needs a SONAME, an ldconfig
        // trigger and an ABI promise this version cannot make yet.
        app.root_module.linkLibrary(app_core);

        const install_app = b.addInstallArtifact(app, .{});
        const linux_app_step = b.step("linux-app", "Build the Linux GTK app (byakaron)");
        linux_app_step.dependOn(&install_app.step);

        const run_app = b.addRunArtifact(app);
        run_app.step.dependOn(&install_app.step);
        run_app.addPassthruArgs();
        const run_linux_app_step = b.step("run-linux-app", "Build and run the Linux GTK app");
        run_linux_app_step.dependOn(&run_app.step);

        // Optional Fcitx5 frontend. Same composer as IBus; skipped when the
        // headers are not installed so a GNOME-only box still `zig build linux`.
        const fcitx_step = b.step("linux-fcitx5", "Build the optional Fcitx5 addon (needs libfcitx5core-dev)");
        if (pkgConfigExists(b, "Fcitx5Core")) {
            const fcitx_core = b.addLibrary(.{
                .linkage = .static,
                .name = "byakaron_fcitx_core",
                .root_module = mod,
            });

            const fcitx = b.addLibrary(.{
                .linkage = .dynamic,
                .name = "byakaronim",
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                    .link_libcpp = true,
                }),
            });
            fcitx.root_module.addCSourceFiles(.{
                .files = &.{"platforms/linux/Fcitx5/engine.cpp"},
                .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-fPIC" },
            });
            fcitx.root_module.addCSourceFiles(.{
                .files = &.{
                    "platforms/linux/Core/composer.c",
                    "platforms/linux/Core/transliterator.c",
                    "platforms/linux/Core/autocomplete.c",
                },
                .flags = &.{ "-std=gnu11", "-Wall", "-Wextra", "-fPIC" },
            });
            fcitx.root_module.addIncludePath(b.path("src/ffi"));
            fcitx.root_module.addIncludePath(b.path("platforms/linux/Core"));
            fcitx.root_module.addIncludePath(b.path("platforms/linux/Fcitx5"));
            fcitx.root_module.linkSystemLibrary("Fcitx5Core", .{});
            fcitx.root_module.linkSystemLibrary("glib-2.0", .{});
            fcitx.root_module.linkLibrary(fcitx_core);

            // Fcitx loads $libdir/fcitx5/byakaron.so (no lib prefix), from the
            // Library=byakaron field in the addon conf.
            const install_fcitx_so = b.addInstallFileWithDir(
                fcitx.getEmittedBin(),
                .lib,
                "fcitx5/byakaron.so",
            );
            const install_fcitx_addon = b.addInstallFileWithDir(
                b.path("platforms/linux/Fcitx5/byakaron-addon.conf"),
                .{ .custom = "share/fcitx5/addon" },
                "byakaron.conf",
            );
            const install_fcitx_im = b.addInstallFileWithDir(
                b.path("platforms/linux/Fcitx5/byakaron.conf"),
                .{ .custom = "share/fcitx5/inputmethod" },
                "byakaron.conf",
            );
            fcitx_step.dependOn(&install_fcitx_so.step);
            fcitx_step.dependOn(&install_fcitx_addon.step);
            fcitx_step.dependOn(&install_fcitx_im.step);
        } else {
            fcitx_step.dependOn(&b.addFail(
                "Fcitx5Core not found — install libfcitx5core-dev or set PKG_CONFIG_PATH",
            ).step);
        }
    }

    // Executable
    const exe = b.addExecutable(.{
        .name = "repl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_mod },
                .{ .name = "tokenization", .module = tokenization_mod },
                .{ .name = "spell", .module = spell_mod },
                .{ .name = "autocomplete", .module = autocomplete_mod },
            },
        }),
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Build / run macOS app via the Xcode project (platforms/macos/scripts/build.sh).
    // The old hand-rolled swiftc graph depended on removed resources (Info-app.plist,
    // AppIcon.icns, iconTemplate.pdf); Xcode owns Info.plist generation and icons now.
    if (builtin.os.tag == .macos) {
        const macos_config = b.option(
            []const u8,
            "macos-config",
            "Xcode configuration for macos / run-macos: debug or release",
        ) orelse "debug";

        const build_script = rootPath(b, "platforms/macos/scripts/build.sh");
        const app_bundle = rootPath(b, "platforms/macos/build/Byakaron.app");

        const macos_build = b.addSystemCommand(&.{ "bash", build_script, macos_config });
        macos_build.setCwd(b.path("platforms/macos"));
        macos_build.has_side_effects = true;
        // Xcode / build_zig.sh need zig on PATH (Cursor toolchain + common shims).
        // Preserve the rest of the inherited environment; only prepend zig + Homebrew.
        const zig_dir = std.fs.path.dirname(b.graph.zig_exe) orelse "/usr/bin";
        const prev_path = macos_build.getEnvMap().get("PATH") orelse "/usr/bin:/bin";
        macos_build.setEnvironmentVariable(
            "PATH",
            b.fmt("{s}:/opt/homebrew/bin:/usr/local/bin:{s}", .{ zig_dir, prev_path }),
        );

        const macos_step = b.step("macos", "Build macOS app (Byakaron.app via xcodebuild)");
        macos_step.dependOn(&macos_build.step);

        const open_app = b.addSystemCommand(&.{ "open", app_bundle });
        open_app.step.dependOn(&macos_build.step);
        open_app.has_side_effects = true;

        const run_macos_step = b.step("run-macos", "Build and open Byakaron.app (not the keyboard)");
        run_macos_step.dependOn(&open_app.step);
    }

    // Web spell UI (platforms/webz) — `zig build run-web` → `zig build dev` there.
    {
        const web_dev = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "dev" });
        web_dev.setCwd(b.path("platforms/webz"));
        const run_web_step = b.step("run-web", "Run platforms/webz (`zig build dev`)");
        run_web_step.dependOn(&web_dev.step);
    }

    // Windows WinUI app — build shared FFI + stage native assets, then `dotnet build`.
    if (builtin.os.tag == .windows) {
        const win_script = rootPath(b, "platforms/windows/scripts/build_zig.ps1");
        const win_zig = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", win_script });
        win_zig.setCwd(b.path("platforms/windows"));
        win_zig.has_side_effects = true;
        const zig_dir = std.fs.path.dirname(b.graph.zig_exe) orelse "C:\\Windows\\System32";
        const prev_path = win_zig.getEnvMap().get("PATH") orelse "";
        win_zig.setEnvironmentVariable("PATH", b.fmt("{s};{s}", .{ zig_dir, prev_path }));
        win_zig.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);

        const windows_step = b.step("windows", "Build Zig FFI DLL and stage for WinUI app");
        windows_step.dependOn(&win_zig.step);
    }

    // Testing
    {
        const lib_unit_tests = b.addTest(.{
            .root_module = mod,
        });
        const t_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_mod },
                .{ .name = "tokenization", .module = tokenization_mod },
                .{ .name = "spell", .module = spell_mod },
                .{ .name = "autocomplete", .module = autocomplete_mod },
            },
        });
        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
        const exe_unit_tests = b.addTest(.{
            .root_module = t_mod,
            .test_runner = .{
                .path = b.path("test/runner.zig"),
                .mode = .simple,
            },
        });
        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}

/// Absolute path to a file/dir relative to the build root (dir with build.zig).
fn rootPath(b: *std.Build, sub: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub) catch @panic("OOM");
}
