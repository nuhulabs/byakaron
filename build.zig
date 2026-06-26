const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("byakaron", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // The C-ABI FFI layer (src/ffi/ffi.zig) uses std.heap.c_allocator so
        // strings can be freed across the FFI boundary; that needs libc.
        .link_libc = true,
    });

    {
        const lib = b.addLibrary(.{
            .linkage = .static,
            .name = "byakaron",
            .root_module = mod,
        });
        // Install the FFI header alongside the lib so consumers can find it.
        lib.installHeader(b.path("src/ffi/byakaron.h"), "byakaron.h");
        b.installArtifact(lib);
    }

    // Executable
    const exe = b.addExecutable(.{
        .name = "repl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Build macOS
    //
    // Replicates platforms/macos/scripts/build.sh as a graph of zig build steps:
    //   1. cargo: build the Rust engine (libavrobangla_engine.a, arm64 release)
    //   2. mac_lib + rearchive: build libbyakaron.a (arm64 ReleaseFast) and
    //      re-pack it with the system `ar` so the macOS linker accepts the
    //      member alignment (the Zig 0.17-dev archiver emits unaligned members).
    //   3. swiftc x2: build the embedded IME helper and the SwiftUI main app.
    //   4. codesign / embed: ad-hoc sign the IME, embed it, ad-hoc sign the app.
    //
    // Only wired up on macOS hosts (xcrun / swiftc / codesign are macOS-only).
    if (builtin.os.tag == .macos) {
        const macos_step = b.step("macos", "Build macOS app (Byakaron.app)");

        // Resolve the macOS SDK path at configure time, mirroring the
        // `xcrun --sdk macosx26.5 --show-sdk-path` call in build.sh.
        const sdk_path = std.mem.trim(
            u8,
            b.run(&.{ "xcrun", "--sdk", "macosx26.5", "--show-sdk-path" }),
            " \t\r\n",
        );
        const sdk_target = "arm64-apple-macos26.0";

        // Fixed locations matching build.sh ($BUILD_DIR, products, resources).
        const engine_dir = rootPath(b, "platforms/macos/engine");
        const rust_lib_dir = rootPath(b, "platforms/macos/engine/target/aarch64-apple-darwin/release");
        const rust_include = rootPath(b, "platforms/macos/engine/include");
        const zig_include = rootPath(b, "src/ffi");
        const zig_lib_dir = rootPath(b, "platforms/macos/build/zig");
        const res_dir = rootPath(b, "platforms/macos/Byakaron/Resources");
        const data_dir = rootPath(b, "platforms/macos/data");
        const ime_name = "Byakaron Keyboard";
        const ime_bundle = rootPath(b, "platforms/macos/build/Byakaron Keyboard.app");
        const app_bundle = rootPath(b, "platforms/macos/build/Byakaron.app");
        const entitlements = rootPath(b, "platforms/macos/Byakaron/Resources/Byakaron.entitlements");
        const bridge_header = rootPath(b, "platforms/macos/Byakaron/Core/Transliteration/BridgeHeader.h");
        const zig_bridge_header = rootPath(b, "platforms/macos/Byakaron/Core/Transliteration/ZigBridge.h");

        // Step 1: Rust engine (cargo build --release --target aarch64-apple-darwin).
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--target", "aarch64-apple-darwin" });
        cargo.setCwd(.{ .cwd_relative = engine_dir });
        cargo.has_side_effects = true;

        // Step 1b: Zig engine library (arm64-macos, ReleaseFast) as a real artifact.
        const mac_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
        const mac_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = mac_target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        const mac_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "byakaron",
            .root_module = mac_mod,
        });

        // Re-archive libbyakaron.a with the system `ar` for member alignment.
        const rearchive = b.addSystemCommand(&.{ "sh", "-c",
            \\set -e
            \\SRC="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            \\rm -rf "$1" && mkdir -p "$1"
            \\cd "$1"
            \\ar x "$SRC"
            \\chmod 644 ./*.o
            \\ar rcs libbyakaron.a ./*.o
        , "_" });
        rearchive.addArg(zig_lib_dir);
        rearchive.addFileArg(mac_lib.getEmittedBin());
        rearchive.has_side_effects = true;

        // Step 2: Embedded IME helper bundle skeleton ("Byakaron Keyboard.app").
        const ime_skel = b.addSystemCommand(&.{ "sh", "-c",
            \\set -e
            \\B="$1"; RES="$2"; DATA="$3"
            \\rm -rf "$B"
            \\mkdir -p "$B/Contents/MacOS"
            \\mkdir -p "$B/Contents/Resources/data"
            \\cp "$RES/Info-keyboard.plist" "$B/Contents/Info.plist"
            \\cp "$RES/iconTemplate.pdf"    "$B/Contents/Resources/iconTemplate.pdf"
            \\cp "$RES/AppIcon.icns"        "$B/Contents/Resources/AppIcon.icns"
            \\cp "$DATA"/*.json             "$B/Contents/Resources/data/"
            \\printf 'APPL????' > "$B/Contents/PkgInfo"
        , "_", ime_bundle, res_dir, data_dir });
        ime_skel.has_side_effects = true;

        // Compile the IME helper executable into the bundle.
        const ime_swiftc = b.addSystemCommand(&.{"swiftc"});
        const ime_sources = [_][]const u8{
            macSrc(b, "Keyboard/Controller/main.swift"),
            macSrc(b, "Keyboard/Controller/AppDelegate.swift"),
            macSrc(b, "Keyboard/CandidateUI/CandidatePanel.swift"),
            macSrc(b, "Keyboard/Activation/SpellServer.swift"),
            macSrc(b, "Keyboard/Phonetic/PhoneticInputController.swift"),
            macSrc(b, "Keyboard/Phonetic/PhoneticInputController+Zig.swift"),
            macSrc(b, "Keyboard/Phonetic/PhoneticDictionary.swift"),
            macSrc(b, "Core/Transliteration/ZigTransliterator.swift"),
            macSrc(b, "Core/Settings/ByakaronSettings.swift"),
        };
        ime_swiftc.addArgs(&ime_sources);
        ime_swiftc.addArgs(&.{
            "-O",
            "-module-name",          "Byakaron",
            "-import-objc-header",    bridge_header,
            "-I",                     rust_include,
            "-I",                     zig_include,
            "-L",                     rust_lib_dir,
            "-lavrobangla_engine",
            "-L",                     zig_lib_dir,
            "-lbyakaron",
            "-sdk",                   sdk_path,
            "-target",                sdk_target,
            "-framework",             "Cocoa",
            "-framework",             "InputMethodKit",
            "-framework",             "SwiftUI",
            "-o",                     b.fmt("{s}/Contents/MacOS/{s}", .{ ime_bundle, ime_name }),
        });
        ime_swiftc.has_side_effects = true;
        ime_swiftc.step.dependOn(&cargo.step);
        ime_swiftc.step.dependOn(&rearchive.step);
        ime_swiftc.step.dependOn(&ime_skel.step);

        // Sign the IME bundle (ad-hoc) with entitlements.
        const ime_sign = b.addSystemCommand(&.{
            "codesign", "--force", "--sign", "-",
            "--entitlements", entitlements,
            ime_bundle,
        });
        ime_sign.has_side_effects = true;
        ime_sign.step.dependOn(&ime_swiftc.step);

        // Step 3: SwiftUI main app bundle skeleton (Byakaron.app).
        const app_skel = b.addSystemCommand(&.{ "sh", "-c",
            \\set -e
            \\A="$1"; RES="$2"; DATA="$3"
            \\rm -rf "$A"
            \\mkdir -p "$A/Contents/MacOS"
            \\mkdir -p "$A/Contents/Resources"
            \\cp "$RES/Info-app.plist" "$A/Contents/Info.plist"
            \\printf 'APPL????' > "$A/Contents/PkgInfo"
            \\cp "$DATA/dictionary.json" "$A/Contents/Resources/dictionary.json"
            \\cp "$RES/AppIcon.icns"      "$A/Contents/Resources/AppIcon.icns"
        , "_", app_bundle, res_dir, data_dir });
        app_skel.has_side_effects = true;

        // Compile the main app executable into the bundle.
        const app_swiftc = b.addSystemCommand(&.{"swiftc"});
        const gui_sources = [_][]const u8{
            macSrc(b, "App/ByakaronApp.swift"),
            macSrc(b, "App/Views/MainView.swift"),
            macSrc(b, "App/Views/SettingsView.swift"),
            macSrc(b, "App/Views/GuideView.swift"),
            macSrc(b, "App/Views/LayoutView.swift"),
            macSrc(b, "App/Views/BanglaSpellTextView.swift"),
            macSrc(b, "App/KeyboardInstaller.swift"),
            macSrc(b, "Core/Prediction/SpellChecker.swift"),
            macSrc(b, "Core/Dictionary/SpellEngine.swift"),
            macSrc(b, "Core/Transliteration/ZigTransliterator.swift"),
            macSrc(b, "Core/Settings/ByakaronSettings.swift"),
        };
        app_swiftc.addArgs(&gui_sources);
        app_swiftc.addArgs(&.{
            "-O",
            "-module-name",        "Byakaron_App",
            "-import-objc-header",  zig_bridge_header,
            "-I",                   zig_include,
            "-L",                   zig_lib_dir,
            "-lbyakaron",
            "-sdk",                 sdk_path,
            "-target",              sdk_target,
            "-framework",           "SwiftUI",
            "-framework",           "AppKit",
            "-framework",           "Carbon",
            "-o",                   b.fmt("{s}/Contents/MacOS/Byakaron", .{app_bundle}),
        });
        app_swiftc.has_side_effects = true;
        app_swiftc.step.dependOn(&rearchive.step);
        app_swiftc.step.dependOn(&app_skel.step);

        // Step 4: Embed the signed IME inside the main app.
        const embed = b.addSystemCommand(&.{ "sh", "-c",
            \\set -e
            \\mkdir -p "$1/Contents/Library/InputMethods"
            \\rm -rf "$1/Contents/Library/InputMethods/$3.app"
            \\cp -R "$2" "$1/Contents/Library/InputMethods/$3.app"
        , "_", app_bundle, ime_bundle, ime_name });
        embed.has_side_effects = true;
        embed.step.dependOn(&app_swiftc.step);
        embed.step.dependOn(&ime_sign.step);

        // Step 5: Sign the outer app last (no --deep, preserves inner signature).
        const app_sign = b.addSystemCommand(&.{
            "codesign", "--force", "--sign", "-",
            "--entitlements", entitlements,
            app_bundle,
        });
        app_sign.has_side_effects = true;
        app_sign.step.dependOn(&embed.step);

        macos_step.dependOn(&app_sign.step);
    }

    // Testing
    {
        const lib_unit_tests = b.addTest(.{
            .root_module = mod,
        });
        const t_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
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

/// Absolute path to a file under the unified macOS source tree
/// (platforms/macos/Byakaron/...).
fn macSrc(b: *std.Build, comptime rel: []const u8) []const u8 {
    return rootPath(b, "platforms/macos/Byakaron/" ++ rel);
}
