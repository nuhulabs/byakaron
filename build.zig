const std = @import("std");
const builtin = @import("builtin");
const ziex = @import("ziex");

fn pkgConfigExists(b: *std.Build, name: []const u8) bool {
    return switch (b.runFallible(&.{ "pkg-config", "--exists", name }, .{
        .stderr_behavior = .ignore,
    })) {
        .success => true,
        else => false,
    };
}

fn pkgConfigVariable(b: *std.Build, pkg: []const u8, variable: []const u8) ?[]const u8 {
    return switch (b.runFallible(&.{ "pkg-config", "--variable", variable, pkg }, .{
        .stderr_behavior = .ignore,
    })) {
        .success => |stdout| std.mem.trim(u8, stdout, " \n\r\t"),
        else => null,
    };
}

// Zig treats -Dtarget=x86_64-linux-gnu.2.31 as a cross compile, so pkg-config
// include flags still apply but the default Debian libdir is not searched.
// Always add it for the Linux C binaries; native builds already have it on
// the gcc path and a duplicate -L is harmless.
fn addHostLibdir(b: *std.Build, mod: *std.Build.Module) void {
    const libdir = pkgConfigVariable(b, "glib-2.0", "libdir") orelse
        "/usr/lib/x86_64-linux-gnu";
    if (libdir.len > 0) {
        mod.addLibraryPath(.{ .cwd_relative = libdir });
    }
}

// Ubuntu 20.04 is GLib 2.64. Compiling on 24.04 without this can inline newer
// GLib APIs and produce a binary that will not load there.
const engine_cflags: []const []const u8 = &.{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_64",
    "-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_64",
};

// gtk+-3.0.pc pulls gdk-pixbuf's -I/usr/include/x86_64-linux-gnu, whose
// time64 typedefs do not exist in Zig's glibc 2.31 headers.
const app_cflags: []const []const u8 = &.{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_64",
    "-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_64",
    "-D__time64_t=long",
};

const fcitx_cflags: []const []const u8 = &.{
    "-std=gnu11",
    "-Wall",
    "-Wextra",
    "-fPIC",
    "-DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_64",
    "-DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_64",
};

/// The build's commands. Each platform is its own step (`zig build macos`,
/// → zig-out/bin); everything else is a verb that takes what it acts on after
/// `--`:
///
///   zig build pack -- <platform>…   release packages → zig-out/pkg
///   zig build dev -- <platform>     install and start it (web: the dev server)
///   zig build e2e -- <suite> [args] end-to-end tests
///   zig build gen -- <what>…        regenerate data and committed sources
///   zig build deps -- linux         system packages; remove -- macos|linux
///
/// Each platform registers its targets with the verbs (`Verb.add`). The args
/// after `--` are only known when the build runs, so a verb's step runs
/// src/build/verb.zig, which picks the targets and runs `zig build <verb>
/// -Dselect=<targets>` with this build's flags: configured with `-Dselect`,
/// the verb's step depends on just those targets' steps.
const Cli = struct {
    pack: Verb = .{ .name = "pack", .about = "Release packages → zig-out/pkg", .multi = true },
    dev: Verb = .{ .name = "dev", .about = "Install and start an app (web: the dev server)", .multi = false },
    e2e: Verb = .{ .name = "e2e", .about = "End-to-end tests (args after the suite go to it)", .multi = false },
    gen: Verb = .{ .name = "gen", .about = "Regenerate data and committed sources", .multi = true },
    deps: Verb = .{ .name = "deps", .about = "Install a platform's system packages", .multi = false },
    remove: Verb = .{ .name = "remove", .about = "Remove an installed app", .multi = false },

    /// `-Dselect`: the targets the dispatcher picked.
    select: ?[]const u8,
    /// This build's own flags, for the dispatcher to configure the same build.
    forward: []const []const u8,

    fn init(b: *std.Build) Cli {
        // Before any b.option() call: the options as given on the command line.
        var forward: std.ArrayList([]const u8) = .empty;
        const a = b.allocator;
        for (b.user_input_options.keys(), b.user_input_options.values()) |name, value| {
            if (std.mem.eql(u8, name, "select")) continue;
            switch (value) {
                .flag => forward.append(a, b.fmt("-D{s}", .{name})) catch @panic("OOM"),
                .scalar => |v| forward.append(a, b.fmt("-D{s}={s}", .{ name, v })) catch @panic("OOM"),
                .list => |l| for (l.items) |v| forward.append(a, b.fmt("-D{s}={s}", .{ name, v })) catch @panic("OOM"),
                else => {},
            }
        }
        switch (b.graph.release_mode) {
            .off => {},
            .any => forward.append(a, "--release") catch @panic("OOM"),
            else => |m| forward.append(a, b.fmt("--release={t}", .{m})) catch @panic("OOM"),
        }
        return .{
            .select = b.option([]const u8, "select", "Targets for a verb step, comma separated (what `zig build <verb> -- <target>` sets)"),
            .forward = forward.items,
        };
    }

    fn finish(cli: *Cli, b: *std.Build) void {
        const dispatch = hostExe(b, "verb", "src/build/verb.zig");
        inline for (.{ &cli.pack, &cli.dev, &cli.e2e, &cli.gen, &cli.deps, &cli.remove }) |v| v.finish(b, cli, dispatch);
    }
};

const Verb = struct {
    name: []const u8,
    about: []const u8,
    /// Several targets at once (`pack -- macos android`); otherwise one
    /// target, and the args after it are its run steps' (`addPassthruArgs`).
    multi: bool,
    targets: std.StringArrayHashMapUnmanaged(Target) = .empty,

    const Target = struct { step: *std.Build.Step, about: []const u8 };

    /// A target of this verb: a step that is not top level, run by
    /// `zig build <verb> -- <name>`.
    fn add(v: *Verb, b: *std.Build, name: []const u8, about: []const u8) *std.Build.Step {
        const step = &b.addWriteFiles().step;
        step.name = b.fmt("{s} {s}", .{ v.name, name });
        v.targets.put(b.allocator, name, .{ .step = step, .about = about }) catch @panic("OOM");
        return step;
    }

    /// A target that cannot run here (wrong host, missing checkout): naming
    /// it fails with `why`.
    fn unavailable(v: *Verb, b: *std.Build, name: []const u8, about: []const u8, why: []const u8) void {
        v.add(b, name, about).dependOn(&b.addFail(why).step);
    }

    fn finish(v: *Verb, b: *std.Build, cli: *const Cli, dispatch: *std.Build.Step.Compile) void {
        const a = b.allocator;
        var names: std.ArrayList(u8) = .empty;
        var usage: std.ArrayList(u8) = .empty;
        usage.print(a, "usage: zig build {s} -- {s}\n", .{ v.name, if (v.multi) "<target>…" else "<target> [args…]" }) catch @panic("OOM");
        for (v.targets.keys(), v.targets.values(), 0..) |name, t, i| {
            names.print(a, "{s}{s}", .{ if (i == 0) "" else ",", name }) catch @panic("OOM");
            usage.print(a, "  {s: <14} {s}\n", .{ name, t.about }) catch @panic("OOM");
        }
        const top = b.step(v.name, b.fmt("{s} (-- {s})", .{ v.about, std.mem.replaceOwned(u8, a, names.items, ",", "|") catch @panic("OOM") }));

        const select = cli.select orelse {
            const run = b.addRunArtifact(dispatch);
            run.addArgs(&.{ b.graph.zig_exe, v.name, if (v.multi) "1" else "0" });
            run.addFileArg(b.addWriteFiles().add(b.fmt("{s}-usage.txt", .{v.name}), usage.items));
            run.addArg(names.items);
            run.addArgs(cli.forward);
            // The same cache and prefix (`--cache-dir`, `-p`) as this build.
            run.addArg("--cache-dir");
            run.addDirectoryArg(b.graph.path(.local_cache, "."));
            run.addArg("--prefix");
            run.addDirectoryArg(b.graph.path(.install_prefix, "."));
            run.addArg("--");
            run.addPassthruArgs();
            run.has_side_effects = true;
            top.dependOn(&run.step);
            return;
        };
        var it = std.mem.splitScalar(u8, select, ',');
        while (it.next()) |name| {
            const t = v.targets.get(name) orelse {
                top.dependOn(&b.addFail(b.fmt("`{s}` is not a `zig build {s}` target\n{s}", .{ name, v.name, usage.items })).step);
                continue;
            };
            top.dependOn(t.step);
        }
    }
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var cli: Cli = .init(b);
    defer cli.finish(b);

    // iAvro (pinned in build.zig.zon) is only fetched with -Diavro: everything
    // the build needs from it is committed (`zig build grammars -Diavro` resyncs).
    const iavro: ?*std.Build.Dependency = if (b.option(bool, "iavro", "Fetch iAvro for `gen -- grammars` (resync) and the iAvro parity test in `test`") orelse false)
        b.lazyDependency("iavro", .{})
    else
        null;

    // Host tools (lexicon, spell_db, prepare) use SQLite through zx.Db.
    const host_sql = hostSqlModule(b);

    // Avro lexicon: iAvro's dictionary, committed as src/AutoComplete/lexicon.zon.
    // Mem embeds it; `db` merges its words into Byakaron.db.
    const avro = avroDictionary(b);
    b.addNamedLazyPath("avro_dictionary", avro.words);
    // All data lands in zig-out/db/. Dictionary.json ships in the macOS bundle
    // (Keyboard/SpellServer.swift).
    const install_lexicon = cli.gen.add(b, "lexicon", "The word list and Dictionary.json → zig-out/db/");
    install_lexicon.dependOn(&b.addInstallFile(avro.json, "db/Dictionary.json").step);
    install_lexicon.dependOn(&b.addInstallFile(avro.words, "db/avro_dictionary.txt").step);
    b.getInstallStep().dependOn(install_lexicon);

    // Spell DB: `zig build db` downloads the bnwiki dump and builds Byakaron.db, every
    // stage cached by the build system. See `addSpellDb`.
    const spell = addSpellDb(b, host_sql, avro.words);
    const spell_db_tool = hostExe(b, "spell_db", "src/build/spell_db.zig");
    spell_db_tool.root_module.addImport("sql", host_sql);
    const db_words = b.option(u32, "db-words", "Keep only the N most frequent words in Byakaron.db (default: $BYAKARON_DB_WORDS, else all; `gen -- d1`: 150000)") orelse
        if (b.graph.environ_map.get("BYAKARON_DB_WORDS")) |s| std.fmt.parseInt(u32, s, 10) catch @panic("BYAKARON_DB_WORDS is not a number") else null;
    const default_spell_db: ?std.Build.LazyPath = if (std.Io.Dir.cwd().access(b.graph.io, "zig-out/db/Byakaron.db", .{})) |_|
        b.path("zig-out/db/Byakaron.db")
    else |_| null;
    const full_db = b.option(std.Build.LazyPath, "spell-db", "Use this Byakaron.db instead of building it") orelse
        (default_spell_db orelse spell.db);
    const spell_db = if (db_words) |n| trimSpellDb(b, spell_db_tool, full_db, n) else full_db;
    b.addNamedLazyPath("spell_db", spell_db);
    const install_spell_db = b.addInstallFile(spell_db, "db/Byakaron.db");
    cli.gen.add(b, "db", "Download bnwiki and build Byakaron.db → zig-out/db/").dependOn(&install_spell_db.step);
    // Regenerate the committed `src/AutoComplete/o_words.zon` from Byakaron.db
    // (see src/build/o_words.zig). Builds the spell DB first, like `zig build db`.
    {
        const gen = hostExe(b, "o_words", "src/build/o_words.zig");
        gen.root_module.addImport("sql", host_sql);
        const run = b.addRunArtifact(gen);
        run.addFileArg(full_db);
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(run.addOutputFileArg("o_words.zon"), "src/AutoComplete/o_words.zon");
        cli.gen.add(b, "o-words", "src/AutoComplete/o_words.zon from Byakaron.db (-Dspell-db=… to reuse one)").dependOn(&update.step);
    }
    // Regenerate the committed `src/ffi/next_words.zon` (next-word predictions
    // for keyboards without the database) from Byakaron.db's bigrams.
    {
        const gen = hostExe(b, "next_words", "src/build/next_words.zig");
        gen.root_module.addImport("sql", host_sql);
        const run = b.addRunArtifact(gen);
        run.addFileArg(full_db);
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(run.addOutputFileArg("next_words.zon"), "src/ffi/next_words.zon");
        cli.gen.add(b, "next-words", "src/ffi/next_words.zon from Byakaron.db (-Dspell-db=… to reuse one)").dependOn(&update.step);
    }
    cli.gen.add(b, "db-debug", "The text-keyed spell_debug.db (large) → zig-out/db/")
        .dependOn(&b.addInstallFile(spell.debug_db, "db/spell_debug.db").step);

    // 150 000 words stay under D1's 500 MB Free-plan database size.
    {
        const d1_db = if (db_words != null) spell_db else trimSpellDb(b, spell_db_tool, full_db, 150_000);
        const gen = b.addRunArtifact(spell_db_tool);
        gen.addArg("d1");
        gen.addFileArg(d1_db);
        const migrations = gen.addOutputDirectoryArg("d1");
        const sync = b.addRunArtifact(spell_db_tool);
        sync.addArg("sync");
        sync.addDirectoryArg(migrations);
        sync.addDirectoryArg(b.graph.path(.install_prefix, "d1"));
        sync.has_side_effects = true;
        cli.gen.add(b, "d1", "Byakaron.db as D1 migrations → zig-out/d1/ (-Ddb-words, -Dspell-db)").dependOn(&sync.step);
    }

    // Shared UI labels (src/locale/*.zon) → every platform's strings.
    const locale = localeStrings(b);

    const engine = addEngine(b, target, optimize, avro, true);
    const zx_mod = engine.zx;
    const tokenization_mod = engine.tokenization;
    const spell_mod = engine.spell;
    const autocomplete_mod = engine.autocomplete;
    const autocomplete_mem_mod = engine.autocomplete_mem;
    const transliteration_mod = engine.transliteration;
    const composer_mod = engine.composer;
    const mod = engine.root;

    // Static lib (macOS Xcode links extracted objects). Shared lib (Windows C#
    // P/Invoke loads byakaron.dll, Android loads libbyakaron.so).
    // `-Dshared` selects dynamic linkage; defaults to true on Android.
    const is_android = target.result.os.tag == .linux and target.result.abi.isAndroid();
    // wasm32-wasi is the web app's Cloudflare Workers build (apps/web/wrangler.jsonc):
    // the default install is just the web server there.
    const is_wasi = target.result.os.tag == .wasi;
    const shared = b.option(bool, "shared", "Build shared library (DLL/dylib/so) for FFI") orelse is_android;
    {
        const lib = b.addLibrary(.{
            .linkage = if (shared) .dynamic else .static,
            .name = "byakaron",
            .root_module = mod,
        });
        // Install the FFI header alongside the lib so consumers can find it.
        lib.installHeader(b.path("src/ffi/byakaron.h"), "byakaron.h");
        if (!is_wasi) b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{}).step);
    }

    // Linux: IBus engine, GTK app, optional Fcitx5, against a pinned Ubuntu
    // sysroot on every host (see `addLinux`).
    addLinux(b, &cli, target, optimize, mod, avro, packSpellDb(b, spell_db_tool, spell_db), &install_spell_db.step, locale);

    // Executable (only built for non-Android, non-wasm targets)
    if (!is_android and !is_wasi) {
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
                    .{ .name = "autocomplete_mem", .module = autocomplete_mem_mod },
                    .{ .name = "transliteration", .module = transliteration_mod },
                    .{ .name = "composer", .module = composer_mod },
                },
            }),
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addPassthruArgs();
        cli.dev.add(b, "repl", "The engine's REPL (zig-out/bin/repl)").dependOn(&run_cmd.step);
    }

    // macOS app (apps/macos) through its Xcode project. The build graph provides
    // everything Xcode links and bundles under zig-out/ (libbyakaron.a +
    // byakaron.h in zig-out/lib/macos/, Dictionary.json + Byakaron.db in zig-out/db/),
    // and src/build/xcode.zig runs xcodebuild with its progress in zig's tree.
    //   zig build macos                → zig-out/bin/Byakaron.app
    //   zig build dev -- macos         → install into /Applications and launch
    //                                    (--release or -Dmacos-config=release for an optimized build)
    //   zig build remove -- macos      → remove the app and keyboard (-Dmacos-remove-user-data)
    //   zig build pack -- macos        → Release build → zig-out/pkg/Byakaron.dmg
    //   zig build gen -- macos-icons   → regenerate Resources/MenuIcon.{pdf,tiff}
    if (builtin.os.tag != .macos) {
        const why = "this needs a macOS host";
        b.step("macos", "Build the macOS app → zig-out/bin/Byakaron.app").dependOn(&b.addFail(why).step);
        b.step("ios", "Build the iOS keyboard for the simulator → zig-out/bin/Byakaron-ios.app").dependOn(&b.addFail(why).step);
        cli.dev.unavailable(b, "macos", "Install the macOS app into /Applications and launch it", why);
        cli.pack.unavailable(b, "macos", "Byakaron.dmg", why);
        cli.remove.unavailable(b, "macos", "The macOS app and keyboard", why);
        cli.dev.unavailable(b, "ios", "Install and launch the iOS app on the booted simulator", why);
        cli.e2e.unavailable(b, "ios", "KeyboardUITests on an iPhone x iOS simulator matrix", why);
    } else {
        // Unset, it follows --release: any mode (fast, safe or small) is Xcode's
        // one Release configuration; none is Debug. The engine is always
        // ReleaseFast (below), whatever this is.
        const config = b.option(
            MacosConfig,
            "macos-config",
            "Xcode configuration for macos / run-macos / install-macos (default: release with --release, else debug)",
        ) orelse if (b.graph.release_mode != .off) MacosConfig.release else MacosConfig.debug;
        const remove_user_data = b.option(bool, "macos-remove-user-data", "uninstall-macos: also remove settings and learned words") orelse false;

        // ReleaseFast always: a Debug build compiles sqlite3.c with UBSan, whose
        // runtime Xcode's linker does not provide.
        const engine_mac = addEngine(b, b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }), .ReleaseFast, avro, false);
        const mac_lib = b.addLibrary(.{ .linkage = .static, .name = "byakaron", .root_module = engine_mac.root });
        // The composer's settings JSON parsing needs f128 helpers (__divtf3, ...)
        // that Xcode's linker has no runtime for.
        mac_lib.bundle_compiler_rt = true;
        const inputs = [_]*std.Build.Step{
            &b.addInstallFileWithDir(mac_lib.getEmittedBin(), .{ .custom = "lib/macos" }, "libbyakaron.a").step,
            &b.addInstallFileWithDir(b.path("src/ffi/byakaron.h"), .{ .custom = "lib/macos" }, "byakaron.h").step,
            // Imported by Core/Transliteration/BridgeHeader.h; Swift reads the
            // labels through tr(_:) in Core/Settings/ByakaronSettings.swift.
            &b.addInstallFileWithDir(locale.header, .{ .custom = "lib/macos" }, "byakaron_strings.h").step,
            install_lexicon,
            &install_spell_db.step,
        };
        const xcode_exe = hostExe(b, "xcode", "src/build/xcode.zig");
        const tool = hostExe(b, "macos", "src/build/macos.zig");
        addIos(b, &cli, avro, locale);

        const app = struct {
            /// Build Byakaron.app for `cfg` into a directory containing it. Each
            /// configuration keeps its own DerivedData (Xcode's incremental state,
            /// under the Zig cache) so two of them can run in one invocation.
            fn build(bb: *std.Build, exe: *std.Build.Step.Compile, deps: []const *std.Build.Step, cfg: MacosConfig) std.Build.LazyPath {
                const name = switch (cfg) {
                    .debug => "Debug",
                    .release => "Release",
                    .sandboxed => "Release-Sandboxed",
                };
                const run = bb.addRunArtifact(exe);
                run.addArgs(&.{ rootPath(bb, "apps/macos/Byakaron.xcodeproj"), "Byakaron", name });
                run.addDirectoryArg(bb.graph.path(.local_cache, bb.fmt("xcode/{s}", .{name})));
                const out = run.addOutputDirectoryArg("app");
                _ = run.addOutputDirectoryArg("log");
                // Xcode tracks its own inputs; always let it decide what to rebuild.
                run.has_side_effects = true;
                for (deps) |d| run.step.dependOn(d);
                return out;
            }
        }.build;

        const install_app = b.addInstallDirectory(.{
            .source_dir = app(b, xcode_exe, &inputs, config),
            .install_dir = .prefix,
            .install_subdir = "bin",
        });
        const installed_app = b.graph.path(.install_prefix, "bin/Byakaron.app");
        b.step("macos", "Build the macOS app → zig-out/bin/Byakaron.app").dependOn(&install_app.step);

        const install = b.addRunArtifact(tool);
        install.addArg("install");
        install.addDirectoryArg(installed_app);
        install.has_side_effects = true;
        install.step.dependOn(&install_app.step);
        cli.dev.add(b, "macos", "Install the macOS app into /Applications and launch it").dependOn(&install.step);

        const uninstall = b.addRunArtifact(tool);
        uninstall.addArg("uninstall");
        if (remove_user_data) uninstall.addArg("--remove-user-data");
        uninstall.has_side_effects = true;
        cli.remove.add(b, "macos", "The macOS app and keyboard (-Dmacos-remove-user-data for settings)").dependOn(&uninstall.step);

        const dmg = b.addRunArtifact(tool);
        dmg.addArg("dmg");
        dmg.addDirectoryArg(app(b, xcode_exe, &inputs, .release).path(b, "Byakaron.app"));
        const dmg_dir = dmg.addOutputDirectoryArg("dmg");
        dmg.has_side_effects = true;
        const install_dmg = b.addInstallDirectory(.{ .source_dir = dmg_dir, .install_dir = .prefix, .install_subdir = "pkg" });
        cli.pack.add(b, "macos", "Release build → zig-out/pkg/Byakaron.dmg").dependOn(&install_dmg.step);

        // Menu-bar icon (template image), drawn by the Swift generators.
        const icons = b.addUpdateSourceFiles();
        for ([_][2][]const u8{
            .{ "apps/macos/scripts/generate_icon_pdf.swift", "MenuIcon.pdf" },
            .{ "apps/macos/scripts/generate_icon.swift", "MenuIcon.tiff" },
        }) |gen| {
            const swift = b.addSystemCommand(&.{"swift"});
            swift.addFileArg(b.path(gen[0]));
            icons.addCopyFileToSource(swift.addOutputFileArg(gen[1]), b.fmt("apps/macos/Resources/{s}", .{gen[1]}));
        }
        cli.gen.add(b, "macos-icons", "apps/macos/Resources/MenuIcon.{pdf,tiff}").dependOn(&icons.step);
    }

    addAndroid(b, &cli, avro, packSpellDb(b, spell_db_tool, spell_db), locale);

    // Web app (apps/web): a ziex app in this build graph, so it shares the cache.
    //   zig build web          the server and its assets → zig-out/
    //   zig build dev -- web   dev server (hot reload)
    // Skipped on Android, where only libbyakaron.so is built.
    if (!is_android) {
        // Engine pieces the page also runs in the browser (autocomplete +
        // Avro transliteration). No target of their own, so the server exe and
        // ziex's client wasm each build them for their own target.
        const web_transliteration = b.createModule(.{ .root_source_file = b.path("src/transliteration/Transliteration.zig") });
        const web_autocomplete = b.createModule(.{
            .root_source_file = b.path("src/AutoComplete.zig"),
            .imports = &.{.{ .name = "transliteration", .module = web_transliteration }},
        });
        const web_autocomplete_mem = b.createModule(.{
            .root_source_file = b.path("src/AutoComplete/Mem.zig"),
            .imports = &.{.{ .name = "autocomplete", .module = web_autocomplete }},
        });
        web_autocomplete_mem.addAnonymousImport("lexicon", .{ .root_source_file = avro.lexicon });
        const web_composer = b.createModule(.{
            .root_source_file = b.path("src/Composer.zig"),
            .imports = &.{
                .{ .name = "autocomplete", .module = web_autocomplete },
                .{ .name = "autocomplete_mem", .module = web_autocomplete_mem },
            },
        });

        const web_exe = b.addExecutable(.{
            .name = "web",
            .root_module = b.createModule(.{
                .root_source_file = b.path("apps/web/app/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "tokenization", .module = tokenization_mod },
                    .{ .name = "spell", .module = spell_mod },
                    .{ .name = "autocomplete", .module = web_autocomplete },
                    // Declared here, before `ziex.init`, so ziex also hands them
                    // to the client wasm (imports added later stay server-only).
                    .{ .name = "autocomplete_mem", .module = web_autocomplete_mem },
                    .{ .name = "transliteration", .module = web_transliteration },
                    .{ .name = "composer", .module = web_composer },
                    .{ .name = "strings", .module = b.createModule(.{ .root_source_file = locale.zig }) },
                },
            }),
        });
        // `zx.db` is Byakaron.db. Natively SQLite is a library only and the app
        // opens zig-out/db/Byakaron.db read-only itself (apps/web/app/pages/spell.zig)
        // instead of ziex's data/db/default.db; on wasm32-wasi (Cloudflare
        // Workers, apps/web/wrangler.jsonc) ziex binds it to the D1 database.
        // Client-side `zx.kv` (browser localStorage) keeps the draft and settings.
        const web = try ziex.init(b, web_exe, .{
            .app = .{
                .path = b.path("apps/web/app"),
                .server = .{ .backend = .std },
                .features = .{
                    .sqlite = if (is_wasi) .enabled else .{},
                    .kv = .{ .client = .enabled },
                },
                .client = .{ .bindings = .{ .build = .enabled, .install_subdir = if (is_wasi) "bindings" else null } },
            },
            .cli = .{ .steps = .{ .dev = "web-dev", .serve = null } },
        });
        // Not a top-level step of its own: `zig build dev -- web` runs it.
        const web_dev = b.top_level_steps.fetchSwapRemove("web-dev").?.value;
        web_dev.step.dependOn(&install_spell_db.step);
        cli.dev.add(b, "web", "apps/web's dev server (hot reload; builds Byakaron.db first)").dependOn(&web_dev.step);
        b.step("web", "Build the web app → zig-out/bin/web + zig-out/static").dependOn(b.getInstallStep());
        // SQLite backends bound to the app's `zx` module so they share its `zx.Db` type.
        inline for (.{
            .{ "spell_sqlite", "src/Spell/Sqlite.zig", "spell", spell_mod },
            .{ "autocomplete_sqlite", "src/AutoComplete/Sqlite.zig", "autocomplete", web_autocomplete },
        }) |m| {
            web.addImport(m[0], b.createModule(.{
                .root_source_file = b.path(m[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = m[2], .module = m[3] },
                    .{ .name = "zx", .module = web.zx_module },
                },
            }));
        }
    }

    addWindows(b, &cli, avro, spell_db);

    // Regenerate the committed iAvro data from the pinned iAvro sources:
    // `zig build grammars -Diavro` (see src/build/grammars.zig, src/build/lexicon.zig).
    {
        const step = cli.gen.add(b, "grammars", "rules.zon, search.zon and lexicon.zon from iAvro (needs -Diavro)");
        if (iavro) |dep| {
            const update = b.addUpdateSourceFiles();

            const gen = hostExe(b, "grammars", "src/build/grammars.zig");
            gen.root_module.addImport("transliteration", b.createModule(.{ .root_source_file = b.path("src/transliteration/Transliteration.zig") }));
            const run = b.addRunArtifact(gen);
            run.addFileArg(dep.path("data.json"));
            run.addFileArg(dep.path("regex.json"));
            run.addFileArg(b.path("src/transliteration/orva.zon"));
            for ([_][]const u8{ "src/transliteration/rules.zon", "src/AutoComplete/search.zon", "src/transliteration/orva.zon" }) |path| {
                update.addCopyFileToSource(run.addOutputFileArg(std.fs.path.basename(path)), path);
            }

            const lex = hostExe(b, "lexicon", "src/build/lexicon.zig");
            lex.root_module.addImport("sql", host_sql);
            lex.root_module.addImport("lexicon_type", b.createModule(.{ .root_source_file = b.path("src/AutoComplete/Lexicon.zig") }));
            const lex_run = b.addRunArtifact(lex);
            lex_run.addFileArg(dep.path("database.db3"));
            lex_run.addFileArg(dep.path("autodict.dct"));
            update.addCopyFileToSource(lex_run.addOutputFileArg("lexicon.zon"), "src/AutoComplete/lexicon.zon");

            step.dependOn(&update.step);
        } else if (!b.user_input_options.contains("iavro")) {
            step.dependOn(&b.addFail("`zig build gen -- grammars` fetches iAvro: run `zig build gen -- grammars -Diavro`").step);
        }
    }

    // Testing
    {
        const t_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_mod },
                .{ .name = "tokenization", .module = tokenization_mod },
                .{ .name = "spell", .module = spell_mod },
                .{ .name = "autocomplete", .module = autocomplete_mod },
                .{ .name = "autocomplete_mem", .module = autocomplete_mem_mod },
                .{ .name = "transliteration", .module = transliteration_mod },
                .{ .name = "composer", .module = composer_mod },
            },
        });
        const test_step = b.step("test", "Run unit tests (-Dlog-level=debug|info|warn|err, default info)");
        // One run over every test binary: test/main.zig runs each one and
        // prints a single list and summary (see addTestRun).
        const log_level = b.option(std.log.Level, "log-level", "std.log level for `zig build test` (default: info)") orelse .info;
        const tests_run = b.addRunArtifact(hostExe(b, "test-main", "test/main.zig"));
        tests_run.addArg(b.fmt("--log-level={t}", .{log_level}));
        test_step.dependOn(&tests_run.step);
        // A test build runs only its root module's tests, so every module gets
        // its own, all through test/runner.zig so each test is listed.
        for ([_]*std.Build.Module{ t_mod, transliteration_mod, tokenization_mod, spell_mod, autocomplete_mod, autocomplete_mem_mod, composer_mod }) |m| {
            addTestRun(b, tests_run, m);
        }
        // Every locale file has every key (src/locale/Locale.zig).
        addTestRun(b, tests_run, localeModule(b, target, optimize));
        // Host build tools (SQL splitter, CSV import).
        addTestRun(b, tests_run, host_sql);
        {
            const prepare_mod = b.createModule(.{
                .root_source_file = b.path("src/data/prepare.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "sql", .module = host_sql }},
            });
            addTestRun(b, tests_run, prepare_mod);
        }
        // Transliteration vs iAvro's AvroParser over every dictionary word
        // (`zig build test -Diavro`).
        if (iavro) |dep| {
            const parity = b.createModule(.{
                .root_source_file = b.path("src/transliteration/reference.zig"),
                .target = target,
                .optimize = optimize,
            });
            parity.addAnonymousImport("iavro_data", .{ .root_source_file = dep.path("data.json") });
            parity.addAnonymousImport("autodict", .{ .root_source_file = dep.path("autodict.dct") });
            parity.addAnonymousImport("avro_words", .{ .root_source_file = avro.words });
            addTestRun(b, tests_run, parity);
        }
    }
}

/// Adds `m`'s tests to the single `zig build test` run: a test binary (Zig
/// runs only a build's root-module tests, so one per module) with
/// test/runner.zig, run by test/main.zig.
fn addTestRun(b: *std.Build, run: *std.Build.Step.Run, m: *std.Build.Module) void {
    run.addArtifactArg(b.addTest(.{
        .root_module = m,
        .test_runner = .{ .path = b.path("test/runner.zig"), .mode = .simple },
    }));
}

fn addWindows(b: *std.Build, cli: *Cli, avro: AvroData, spell_db: std.Build.LazyPath) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const engine = addEngine(b, target, .ReleaseFast, avro, false);
    const ffi = b.addLibrary(.{ .linkage = .dynamic, .name = "byakaron", .root_module = engine.root });

    // The IME loads byakaron.dll at runtime, so it only needs the header.
    const ime_mod = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libcpp = true });
    ime_mod.addCSourceFiles(.{
        .root = b.path("apps/windows/Keyboard"),
        .files = &.{ "DllMain.cpp", "KeyHandler.cpp", "TextService.cpp", "Composer.cpp", "Settings.cpp", "CandidateWindow.cpp" },
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-D_WINDOWS", "-D_USRDLL" },
    });
    ime_mod.addIncludePath(b.path("apps/windows/Keyboard"));
    ime_mod.addIncludePath(b.path("src/ffi"));
    for ([_][]const u8{ "ole32", "oleaut32", "uuid", "advapi32", "user32", "gdi32" }) |lib| {
        ime_mod.linkSystemLibrary(lib, .{});
    }
    const ime = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "ByakaronIME",
        .root_module = ime_mod,
        .win32_module_definition = b.path("apps/windows/Keyboard/ByakaronIME.def"),
    });

    // `windows`: the IME DLLs (cross-compiled from any host) and, on Windows,
    // a Debug build of the WinUI app (what CI builds), like `linux` and `macos`.
    const windows_step = b.step("windows", "Build the IME DLLs → zig-out/bin/ime/ and, on Windows, the WinUI app (Debug)");
    windows_step.dependOn(&b.addInstallFileWithDir(ime.getEmittedBin(), .{ .custom = "bin/ime" }, "ByakaronIME.dll").step);
    windows_step.dependOn(&b.addInstallFileWithDir(ffi.getEmittedBin(), .{ .custom = "bin/ime" }, "byakaron.dll").step);
    if (builtin.os.tag != .windows) {
        const why = "the WinUI app needs a Windows host (`zig build windows` cross-compiles the IME DLLs from here)";
        cli.pack.unavailable(b, "windows", "zig-out/pkg/Byakaron-Setup.exe", why);
        cli.dev.unavailable(b, "windows", "Build and run the WinUI app (Debug)", why);
        return;
    }

    const version = b.option([]const u8, "windows-version", "Installer version for `pack -- windows` (default: $BYAKARON_VERSION, else 1.0.0)");
    const iscc_exe = b.option(std.Build.LazyPath, "windows-iscc", "Inno Setup's ISCC.exe for `pack -- windows` (default: Program Files, then PATH)") orelse
        b.findProgramLazy(.{ .names = &.{
            "C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe",
            "C:\\Program Files\\Inno Setup 6\\ISCC.exe",
            "ISCC",
        } });
    const proj = b.path("apps/windows/Byakaron/Byakaron.csproj");

    // The DLLs Byakaron.csproj copies next to the app; Byakaron.db only for
    // `dev -- windows` and the installer, so `windows` does not build the spell DB.
    const stage_dlls = b.addUpdateSourceFiles();
    stage_dlls.addCopyFileToSource(ffi.getEmittedBin(), "apps/windows/Byakaron/Native/byakaron.dll");
    stage_dlls.addCopyFileToSource(ime.getEmittedBin(), "apps/windows/Byakaron/ime/ByakaronIME.dll");
    stage_dlls.addCopyFileToSource(ffi.getEmittedBin(), "apps/windows/Byakaron/ime/byakaron.dll");
    const stage = b.addUpdateSourceFiles();
    stage.addCopyFileToSource(spell_db, "apps/windows/Byakaron/Native/Byakaron.db");
    stage.step.dependOn(&stage_dlls.step);

    // MSBuild tracks its own inputs; always let it run.
    const app = b.addSystemCommand(&.{ "dotnet", "build" });
    app.addFileArg(proj);
    app.addArgs(&.{ "-c", "Debug", "-p:Platform=x64" });
    app.has_side_effects = true;
    app.step.dependOn(&stage_dlls.step);
    windows_step.dependOn(&app.step);

    // MSBuild and ISCC track their own inputs; always let them run.
    const publish = b.addSystemCommand(&.{ "dotnet", "publish" });
    publish.addFileArg(proj);
    publish.addArgs(&.{ "-c", "Release", "-r", "win-x64", "-p:Platform=x64", "--self-contained", "true" });
    publish.addArgs(&.{ "-p:WindowsAppSDKSelfContained=true", "-p:PublishTrimmed=false", "-p:PublishReadyToRun=true", "-o" });
    const payload = publish.addOutputDirectoryArg("Byakaron");
    publish.has_side_effects = true;
    publish.step.dependOn(&stage.step);

    const iscc = std.Build.Step.Run.create(b, "run ISCC");
    iscc.addFileArg(iscc_exe);
    iscc.addPrefixedDirectoryArg("/DPublishDir=", payload);
    const setup_dir = iscc.addPrefixedOutputDirectoryArg("/DOutputDir=", "setup");
    if (version) |v| iscc.addArg(b.fmt("/DAppVersion={s}", .{v}));
    iscc.addFileArg(b.path("apps/windows/installer/Byakaron.iss"));
    iscc.has_side_effects = true;
    const package_step = cli.pack.add(b, "windows", "The installer → zig-out/pkg/Byakaron-Setup.exe");
    package_step.dependOn(&b.addInstallFileWithDir(setup_dir.path(b, "Byakaron-Setup.exe"), .{ .custom = "pkg" }, "Byakaron-Setup.exe").step);
    package_step.dependOn(&b.addInstallDirectory(.{ .source_dir = payload, .install_dir = .{ .custom = "bin" }, .install_subdir = "Byakaron" }).step);

    const run = b.addSystemCommand(&.{ "dotnet", "run", "--project" });
    run.addFileArg(proj);
    run.addArgs(&.{ "-c", "Debug", "-p:Platform=x64", "--no-launch-profile" });
    run.has_side_effects = true;
    run.step.dependOn(&stage.step);
    cli.dev.add(b, "windows", "Build and run the WinUI app (Debug)").dependOn(&run.step);
}

/// The engine's Zig modules for one target: the FFI root (`byakaron`) and what
/// it is built from. `exported` registers them for dependents (`b.addModule`);
/// the Linux cross build makes an unexported copy for its own target.
const Engine = struct {
    zx: *std.Build.Module,
    tokenization: *std.Build.Module,
    spell: *std.Build.Module,
    autocomplete: *std.Build.Module,
    autocomplete_mem: *std.Build.Module,
    transliteration: *std.Build.Module,
    composer: *std.Build.Module,
    jni: ?*std.Build.Module,
    root: *std.Build.Module,
};

fn addEngine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    avro: AvroData,
    exported: bool,
) Engine {
    // zx (ziex) with SQLite — used by Spell/Sqlite.zig. `app_opts` is required by
    // zx.App even though we only consume zx.Db from the library.
    const ziex_dep = b.dependency("ziex", .{
        .target = target,
        .optimize = optimize,
        .lsp = false,
        .@"feature-sqlite" = true,
    });
    const zx_mod = ziex_dep.module("zx");

    // zig-jni for the Android JNI bridge (src/ffi/jni.zig). Android only: the
    // JNI headers do not translate for other targets (e.g. win32/jni_md.h).
    const jni_mod: ?*std.Build.Module = if (target.result.abi.isAndroid()) blk: {
        const jni_dep = b.dependency("jni", .{
            .target = target,
            .optimize = optimize,
        });
        const cjni = b.addTranslateC(.{
            .root_source_file = b.path("src/ffi/jni_wrapper.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cjni.addIncludePath(b.path("src/ffi/include"));
        cjni.addIncludePath(jni_dep.path("src/include"));
        const m = module(b, exported, "JNI", .{
            .root_source_file = jni_dep.path("src/main/zig/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        m.addImport("cjni", cjni.createModule());
        break :blk m;
    } else null;
    zx_mod.addOptions("app_opts", zxLibraryOptions(b));

    // Tokenizer-only module (no FFI / libc) for wasm-friendly consumers like apps/web.
    const tokenization_mod = module(b, exported, "tokenization", .{
        .root_source_file = b.path("src/tokenization/tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spell_mod = module(b, exported, "spell", .{
        .root_source_file = b.path("src/Spell.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tokenization", .module = tokenization_mod },
        },
    });

    const transliteration_mod = module(b, exported, "transliteration", .{
        .root_source_file = b.path("src/transliteration/Transliteration.zig"),
        .target = target,
        .optimize = optimize,
    });

    const autocomplete_mod = module(b, exported, "autocomplete", .{
        .root_source_file = b.path("src/AutoComplete.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "transliteration", .module = transliteration_mod },
        },
    });

    const autocomplete_mem_mod = module(b, exported, "autocomplete_mem", .{
        .root_source_file = b.path("src/AutoComplete/Mem.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "autocomplete", .module = autocomplete_mod },
        },
    });
    autocomplete_mem_mod.addAnonymousImport("lexicon", .{ .root_source_file = avro.lexicon });

    const composer_mod = module(b, exported, "composer", .{
        .root_source_file = b.path("src/Composer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "autocomplete", .module = autocomplete_mod },
            .{ .name = "autocomplete_mem", .module = autocomplete_mem_mod },
        },
    });

    const mod = module(b, exported, "byakaron", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // The C-ABI FFI layer (src/ffi/ffi.zig) uses std.heap.c_allocator so
        // strings can be freed across the FFI boundary; that needs libc.
        .link_libc = true,
        .imports = &.{
            .{ .name = "tokenization", .module = tokenization_mod },
            .{ .name = "spell", .module = spell_mod },
            .{ .name = "autocomplete", .module = autocomplete_mod },
            .{ .name = "autocomplete_mem", .module = autocomplete_mem_mod },
            .{ .name = "transliteration", .module = transliteration_mod },
            .{ .name = "composer", .module = composer_mod },
        },
    });
    // SQLite (zx.Db) for the spell engine; not on iOS, where the FFI leaves the
    // spell engine out (src/ffi/ffi.zig `sqlite`), so sqlite3.c is not built.
    if (target.result.os.tag != .ios) mod.addImport("zx", zx_mod);
    if (jni_mod) |m| mod.addImport("jni", m);

    return .{
        .zx = zx_mod,
        .tokenization = tokenization_mod,
        .spell = spell_mod,
        .autocomplete = autocomplete_mod,
        .autocomplete_mem = autocomplete_mem_mod,
        .transliteration = transliteration_mod,
        .composer = composer_mod,
        .jni = jni_mod,
        .root = mod,
    };
}

fn module(b: *std.Build, exported: bool, name: []const u8, options: std.Build.Module.CreateOptions) *std.Build.Module {
    return if (exported) b.addModule(name, options) else b.createModule(options);
}

/// Linux targets, built for glibc 2.31 (Ubuntu 20.04+) against a sysroot
/// unpacked from pinned Ubuntu 24.04 packages (`linuxSysroot`) on every host,
/// so a Linux, macOS or Windows machine produces the same binaries without the
/// -dev packages, a Linux box or a container. `-Dlinux-arch` picks the CPU.
///
/// `zig build linux` builds the IBus engine and the GTK companion app (and,
/// on a Linux host, the GSettings schemas and the Fcitx5 addon when its
/// headers are installed).
///
/// On a Linux host, src/build/linux.zig drives the rest:
///   zig build pack -- linux          → zig-out/pkg/byakaron_<ver>_<arch>.deb
///   zig build pack -- linux-arch     → zig-out/pkg/byakaron-<ver>-1-<arch>.pkg.tar.zst (Arch)
///   zig build pack -- linux-flatpak  → the GTK app as a Flatpak bundle
///   zig build dev -- linux           → register the engine with the running ibus-daemon
///   zig build dev -- linux-app       → run the GTK app
///   zig build dev -- linux-system    → sudo -E: install into /usr
///   zig build remove -- linux        → sudo: remove it
///   zig build deps -- linux          → sudo: apt packages (`deps -- linux --test` adds the test toolchain)
///   zig build e2e -- linux           → what CI runs (glibc, smoke, IME test, probes, icon, AppStream)
///   zig build e2e -- linux-wayland   → typing into GTK3/GTK4 on a private headless GNOME Shell
///   zig build e2e -- linux-install   → the local .deb in clean Ubuntu/Debian containers (Docker)
///
/// The packages and the system install always use ReleaseFast builds,
/// whatever `-Doptimize` is.
///
/// `-Dlinux-system-libs` (Linux hosts only) links the system IBus/GTK through
/// pkg-config instead, honouring `-Dtarget`, for offline or distro builds.
/// Running the app, the GSettings schema and Fcitx5 always need a Linux host.
fn addLinux(
    b: *std.Build,
    cli: *Cli,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    avro: AvroData,
    spell_db: std.Build.LazyPath,
    install_spell_db: *std.Build.Step,
    locale: LocaleStrings,
) void {
    const host_linux = builtin.os.tag == .linux;
    const system_libs = b.option(bool, "linux-system-libs", "Link the Linux targets against system IBus/GTK via pkg-config (Linux host)") orelse false;
    const arch = b.option(LinuxArch, "linux-arch", "CPU for the Linux targets (default: host CPU on Linux, else x86_64)") orelse
        if (host_linux and builtin.cpu.arch == .aarch64) .aarch64 else .x86_64;
    const misuse: ?*std.Build.Step = if (system_libs and !host_linux)
        &b.addFail("-Dlinux-system-libs needs a Linux host").step
    else
        null;
    const native = system_libs and host_linux;
    const linux_target = if (native) target else b.resolveTargetQuery(.{
        .cpu_arch = switch (arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
        },
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{ .major = 2, .minor = 31, .patch = 0 },
    });
    const core = if (native) mod else addEngine(b, linux_target, optimize, avro, false).root;
    const sysroot: ?Sysroot = if (native) null else linuxSysroot(b, arch);
    // The packages and the system install always ship ReleaseFast binaries, whatever
    // the top-level -Doptimize is (a Debug engine would carry sanitizer runtimes
    // and debug info). With -Doptimize=fast they are the same binaries as `linux`.
    const rel_core = if (optimize == .fast) core else addEngine(b, if (native) target else linux_target, .fast, avro, false).root;

    const ime = linuxIme(b, linux_target, optimize, core, sysroot);

    const install_ime = b.addInstallArtifact(ime, .{});
    const linux_step = b.step("linux", "Build Linux IBus + GTK app → zig-out/bin/{byakaron-ibus,byakaron}");
    if (misuse) |f| linux_step.dependOn(f);
    linux_step.dependOn(&install_ime.step);

    // Integration test: drives the engine through a private IBus input
    // context, so it needs a daemon with the engine registered (`zig build
    // run-linux`; `linux-ci` starts a private daemon and runs it).
    const ime_test = b.addExecutable(.{
        .name = "byakaron-ime-test",
        .root_module = b.createModule(.{
            .target = linux_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ime_test.root_module.addCSourceFiles(.{
        .files = &.{"apps/linux/tests/ime_test.c"},
        .flags = engine_cflags,
    });
    linkLinux(b, ime_test.root_module, sysroot, &.{ "ibus-1.0", "glib-2.0", "gobject-2.0" });
    ime_test.linker_allow_shlib_undefined = true;

    const install_ime_test = b.addInstallArtifact(ime_test, .{});

    // Loads an icon with gdk-pixbuf at given sizes (`e2e -- linux` and, inside
    // the containers, `e2e -- linux-install`), so it is built like the IME
    // test: for glibc 2.31 against the sysroot.
    const icon_check = b.addExecutable(.{
        .name = "byakaron-icon-check",
        .root_module = b.createModule(.{ .target = linux_target, .optimize = optimize, .link_libc = true }),
    });
    icon_check.root_module.addCSourceFiles(.{ .files = &.{"apps/linux/tests/icon_check.c"}, .flags = engine_cflags });
    linkLinux(b, icon_check.root_module, sysroot, &.{ "gdk-pixbuf-2.0", "gobject-2.0", "glib-2.0" });
    icon_check.linker_allow_shlib_undefined = true;
    install_ime_test.step.dependOn(&b.addInstallArtifact(icon_check, .{}).step);

    // C ABI smoke test. It compiles the Core glue in (not just links the core)
    // because it drives the composer through it, as the IME shells do; that
    // pulls in glib/gio, which are dependencies of the glue, not of the core.
    // Needs no IBus daemon.
    const smoke_core = b.addLibrary(.{
        .linkage = .static,
        .name = "byakaron_smoke_core",
        .root_module = core,
    });
    const smoke = b.addExecutable(.{
        .name = "byakaron-smoke",
        .root_module = b.createModule(.{
            .target = linux_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "apps/linux/tests/smoke.c",
            "apps/linux/Core/composer.c",
            "apps/linux/Core/prefs.c",
            "apps/linux/Core/spell.c",
            "apps/linux/Core/update.c",
        },
        .flags = engine_cflags,
    });
    smoke.root_module.addIncludePath(b.path("src/ffi"));
    smoke.root_module.addIncludePath(b.path("apps/linux/Core"));
    linkLinux(b, smoke.root_module, sysroot, &.{ "glib-2.0", "gobject-2.0", "gio-2.0" });
    smoke.root_module.linkLibrary(smoke_core);
    smoke.linker_allow_shlib_undefined = true;
    const install_smoke = b.addInstallArtifact(smoke, .{});

    // GTK3 companion app (same `linux` / `linux-app` install). Built against
    // the pinned sysroot like the engine, so no libgtk-3-dev is required.
    // GTK3 3.24 is on Ubuntu 20.04, 22.04, and 24.04; GTK4 / libadwaita 1.4
    // are not.
    const app = linuxApp(b, linux_target, optimize, core, sysroot, locale);

    const install_app = b.addInstallArtifact(app, .{});
    linux_step.dependOn(&install_app.step);

    // Running the app and compiling the GSettings schema (glib-compile-schemas)
    // need a Linux host; elsewhere the build stops at the binaries.
    if (host_linux) {
        const run_app = b.addRunArtifact(app);
        run_app.step.dependOn(&install_app.step);
        run_app.addPassthruArgs();
        cli.dev.add(b, "linux-app", "Run the GTK app").dependOn(&run_app.step);

        // GSettings schema: compiled into zig-out/share/glib-2.0/schemas so an
        // uninstalled engine/app can find it next to the binary (or via
        // GSETTINGS_SCHEMA_DIR for `zig build dev -- linux-app`, whose artifact
        // lives in the cache rather than zig-out/bin).
        const compile_schemas = b.addSystemCommand(&.{
            "sh",
            "-c",
            \\set -eu
            \\dest="$1"
            \\src="$2"
            \\mkdir -p "$dest"
            \\cp "$src" "$dest/dev.nuhu.labs.Byakaron.gschema.xml"
            \\glib-compile-schemas "$dest"
            ,
            "byk-compile-schemas",
        });
        const schema_dir = compile_schemas.addOutputDirectoryArg("gsettings-schemas");
        compile_schemas.addFileArg(b.path("apps/linux/Resources/dev.nuhu.labs.Byakaron.gschema.xml"));
        const install_schemas = b.addInstallDirectory(.{
            .source_dir = schema_dir,
            .install_dir = .{ .custom = "share/glib-2.0/schemas" },
            .install_subdir = "",
        });
        linux_step.dependOn(&install_schemas.step);
        run_app.step.dependOn(&install_schemas.step);
        run_app.setEnvironmentVariable("GSETTINGS_SCHEMA_DIR", "zig-out/share/glib-2.0/schemas");
    }

    // Optional Fcitx5 frontend. Same composer as IBus; built for `e2e -- linux`
    // and the system install when the headers are installed, skipped
    // otherwise so a GNOME-only box still installs.
    const fcitx_step = &b.addWriteFiles().step;
    var fcitx_so: ?std.Build.LazyPath = null;
    var fcitx_release_so: ?std.Build.LazyPath = null;
    // Fcitx5 is C++ against the host's libFcitx5Core, so it always uses the
    // system libraries (it is not in the pinned sysroot).
    if (host_linux and pkgConfigExists(b, "Fcitx5Core")) {
        const fcitx = linuxFcitx(b, linux_target, optimize, core);

        // Fcitx loads $libdir/fcitx5/byakaron.so (no lib prefix), from the
        // Library=byakaron field in the addon conf.
        const install_fcitx_so = b.addInstallFileWithDir(
            fcitx,
            .lib,
            "fcitx5/byakaron.so",
        );
        const install_fcitx_addon = b.addInstallFileWithDir(
            b.path("apps/linux/Fcitx5/byakaron-addon.conf"),
            .{ .custom = "share/fcitx5/addon" },
            "byakaron.conf",
        );
        const install_fcitx_im = b.addInstallFileWithDir(
            b.path("apps/linux/Fcitx5/byakaron.conf"),
            .{ .custom = "share/fcitx5/inputmethod" },
            "byakaron.conf",
        );
        fcitx_step.dependOn(&install_fcitx_so.step);
        fcitx_step.dependOn(&install_fcitx_addon.step);
        fcitx_step.dependOn(&install_fcitx_im.step);
        fcitx_so = fcitx;
        if (optimize != .fast) {
            fcitx_release_so = linuxFcitx(b, linux_target, .fast, rel_core);
        } else {
            fcitx_release_so = fcitx_so;
        }
    }

    // GTK4 display-path probes (wayland_probe / wayland_type
    // helpers). Run on the host against the system GTK4, so they are optional:
    // `e2e -- linux` runs them when built.
    const wayland_step = &b.addWriteFiles().step;
    var have_wayland = false;
    // What `e2e -- linux-wayland` types into (one source for GTK 3 and 4) and
    // drives it with (the RemoteDesktop portal), on the host's libraries.
    const wayland_e2e_step = &b.addWriteFiles().step;
    const hostTest = struct {
        fn add(bb: *std.Build, opt: std.builtin.OptimizeMode, name: []const u8, src: []const u8, lib: []const u8) *std.Build.Step {
            const exe = bb.addExecutable(.{
                .name = name,
                .root_module = bb.createModule(.{ .target = bb.graph.host, .optimize = opt, .link_libc = true }),
            });
            exe.root_module.addCSourceFiles(.{ .files = &.{src}, .flags = &.{ "-std=gnu11", "-Wall", "-Wextra" } });
            exe.root_module.linkSystemLibrary(lib, .{});
            return &bb.addInstallArtifact(exe, .{}).step;
        }
    }.add;
    if (host_linux and pkgConfigExists(b, "gio-2.0")) {
        wayland_e2e_step.dependOn(hostTest(b, optimize, "byakaron-wayland-rdtest", "apps/linux/tests/wayland_rdtest.c", "gio-2.0"));
    }
    if (host_linux and pkgConfigExists(b, "gtk+-3.0")) {
        wayland_e2e_step.dependOn(hostTest(b, optimize, "byakaron-wayland-textapp-gtk3", "apps/linux/tests/wayland_textapp.c", "gtk+-3.0"));
    }
    if (host_linux and pkgConfigExists(b, "gtk4")) {
        have_wayland = true;
        wayland_e2e_step.dependOn(hostTest(b, optimize, "byakaron-wayland-textapp-gtk4", "apps/linux/tests/wayland_textapp.c", "gtk4"));
        for ([_][2][]const u8{
            .{ "byakaron-wayland-probe", "apps/linux/tests/wayland_probe.c" },
            .{ "byakaron-wayland-type", "apps/linux/tests/wayland_type.c" },
        }) |t| {
            const exe = b.addExecutable(.{
                .name = t[0],
                .root_module = b.createModule(.{
                    .target = b.graph.host,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            exe.root_module.addCSourceFiles(.{ .files = &.{t[1]}, .flags = &.{ "-std=gnu11", "-Wall", "-Wextra" } });
            exe.root_module.linkSystemLibrary("gtk4", .{});
            wayland_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    }

    // Packaging, install and CI go through src/build/linux.zig. The build graph
    // above has already produced every binary they use; the tool never calls
    // `zig build` itself.
    const package_step = cli.pack.add(b, "linux", "zig-out/pkg/byakaron_<ver>_<arch>.deb (always ReleaseFast)");
    const arch_package_step = cli.pack.add(b, "linux-arch", "zig-out/pkg/byakaron-<ver>-1-<arch>.pkg.tar.zst for Arch Linux");
    const flatpak_step = cli.pack.add(b, "linux-flatpak", "zig-out/pkg/dev.nuhu.labs.Byakaron.flatpak, the GTK app only (needs flatpak)");
    const run_step = cli.dev.add(b, "linux", "Register the IBus engine with the running ibus-daemon (Ctrl-C to unregister)");
    const install_step = cli.dev.add(b, "linux-system", "Install the IBus engine + GTK app into /usr (sudo -E; -Dlinux-install-db for Byakaron.db)");
    const uninstall_step = cli.remove.add(b, "linux", "The system install (sudo)");
    const deps_step = cli.deps.add(b, "linux", "apt-get the Linux runtime packages (sudo; `--test` adds the test toolchain)");
    const ci_step = cli.e2e.add(b, "linux", "The Linux CI checks (glibc, smoke, IME test, probes, icon, AppStream)");
    const e2e_step = cli.e2e.add(b, "linux-wayland", "Type into GTK3/GTK4 apps on a private headless GNOME Shell (needs gnome-shell)");
    const install_test_step = cli.e2e.add(b, "linux-install", "Install the built .deb in clean Docker images and test it (needs docker; args: images)");
    if (misuse) |f| for ([_]*std.Build.Step{ package_step, arch_package_step, run_step, install_step, ci_step, e2e_step, install_test_step }) |s| s.dependOn(f);

    if (!host_linux) {
        for ([_]*std.Build.Step{ package_step, arch_package_step, flatpak_step, install_step, uninstall_step, deps_step, run_step, ci_step, e2e_step, install_test_step }) |s| {
            s.dependOn(&b.addFail("this needs a Linux host").step);
        }
        return;
    }

    const tool = hostExe(b, "linux", "src/build/linux.zig");
    const root = rootPath(b, "");
    const resources = [_][]const u8{
        "apps/linux/Resources/byakaron.xml.in",
        "apps/linux/Resources/byakaron-app.desktop.in",
        "apps/linux/Resources/byakaron.svg",
        "apps/linux/Resources/dev.nuhu.labs.Byakaron.gschema.xml",
        "apps/linux/Resources/dev.nuhu.labs.Byakaron.metainfo.xml",
        "apps/linux/Resources/gnome-shell/panel.css",
        "apps/linux/Resources/gnome-shell/byakaron-panel@nuhulabs.com/metadata.json",
        "apps/linux/Resources/gnome-shell/byakaron-panel@nuhulabs.com/extension.js",
        "apps/linux/Resources/gnome-shell/byakaron-panel-legacy@nuhulabs.com/metadata.json",
        "apps/linux/Resources/gnome-shell/byakaron-panel-legacy@nuhulabs.com/extension.js",
        "apps/linux/Fcitx5/byakaron-addon.conf",
        "apps/linux/Fcitx5/byakaron.conf",
    };

    // What gets packaged or installed is always ReleaseFast (`rel_*`), whatever
    // -Doptimize says for the development steps.
    const rel_ime = if (optimize == .fast) ime else linuxIme(b, linux_target, .fast, rel_core, sysroot);
    const rel_app = if (optimize == .fast) app else linuxApp(b, linux_target, .fast, rel_core, sysroot, locale);

    const package = b.addRunArtifact(tool);
    package.addArgs(&.{ "package-deb", root });
    package.addFileArg(rel_ime.getEmittedBin());
    package.addFileArg(rel_app.getEmittedBin());
    package.addFileArg(spell_db);
    const deb_dir = package.addOutputDirectoryArg("deb");
    // No Fcitx5 addon in the .deb: it is built against one Fcitx5's C++ API,
    // and the .deb is one file for every release. The system install
    // (`dev -- linux-system`) builds it on the machine that uses it.
    package.setEnvironmentVariable("BYK_DEB_ARCH", switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
    });
    for (resources) |r| package.addFileInput(b.path(r));
    package.step.dependOn(install_spell_db);
    package_step.dependOn(&b.addInstallDirectory(.{ .source_dir = deb_dir, .install_dir = .prefix, .install_subdir = "pkg" }).step);

    // The same payload as a pacman package, for Arch Linux and the systems
    // built on it. Like the .deb, no Fcitx5 addon.
    const arch_package = b.addRunArtifact(tool);
    arch_package.addArgs(&.{ "package-arch", root });
    arch_package.addFileArg(rel_ime.getEmittedBin());
    arch_package.addFileArg(rel_app.getEmittedBin());
    arch_package.addFileArg(spell_db);
    const arch_dir = arch_package.addOutputDirectoryArg("arch");
    arch_package.setEnvironmentVariable("BYK_PACMAN_ARCH", switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
    });
    for (resources) |r| arch_package.addFileInput(b.path(r));
    arch_package.step.dependOn(install_spell_db);
    arch_package_step.dependOn(&b.addInstallDirectory(.{ .source_dir = arch_dir, .install_dir = .prefix, .install_subdir = "pkg" }).step);

    const install_db = b.option(bool, "linux-install-db", "dev -- linux-system: build Byakaron.db and install it too (default: only if zig-out/db/Byakaron.db exists)") orelse false;
    const install = b.addRunArtifact(tool);
    install.addArgs(&.{ "install", root });
    install.addFileArg(rel_ime.getEmittedBin());
    install.addFileArg(rel_app.getEmittedBin());
    if (install_db) {
        install.addFileArg(spell_db);
        install.step.dependOn(install_spell_db);
    } else {
        const db = rootPath(b, "zig-out/db/Byakaron.db");
        if (std.Io.Dir.cwd().access(b.graph.io, db, .{})) |_| install.addArg(db) else |_| {}
    }
    if (fcitx_release_so) |so| {
        install.addArg("--fcitx");
        install.addFileArg(so);
    }
    install.has_side_effects = true;
    install_step.dependOn(&install.step);

    const uninstall = b.addRunArtifact(tool);
    uninstall.addArg("uninstall");
    uninstall.has_side_effects = true;
    uninstall_step.dependOn(&uninstall.step);

    const deps = b.addRunArtifact(tool);
    deps.addArg("deps");
    deps.addPassthruArgs();
    deps.has_side_effects = true;
    deps_step.dependOn(&deps.step);

    const dev = b.addRunArtifact(tool);
    dev.addArgs(&.{ "dev", root });
    dev.addFileArg(ime.getEmittedBin());
    dev.has_side_effects = true;
    dev.step.dependOn(linux_step);
    run_step.dependOn(&dev.step);

    const ci = b.addRunArtifact(tool);
    ci.addArgs(&.{ "ci", root });
    ci.has_side_effects = true;
    ci.step.dependOn(linux_step);
    ci.step.dependOn(&install_ime_test.step);
    ci.step.dependOn(&install_smoke.step);
    if (fcitx_so != null) ci.step.dependOn(fcitx_step);
    // Without Fcitx5's headers the addon is not built, and a byakaron.so left in
    // zig-out by an earlier build (against a Fcitx5 since removed) is not this
    // build's: `e2e -- linux` must not check it.
    ci.setEnvironmentVariable("BYK_FCITX_BUILT", if (fcitx_so != null) "1" else "0");
    if (have_wayland) ci.step.dependOn(wayland_step);
    ci_step.dependOn(&ci.step);

    // The GTK app alone as a Flatpak (the IBus engine cannot live in a sandbox).
    const flatpak = b.addRunArtifact(tool);
    flatpak.addArgs(&.{ "package-flatpak", root });
    flatpak.addFileArg(rel_app.getEmittedBin());
    const flatpak_dir = flatpak.addOutputDirectoryArg("flatpak");
    flatpak.setEnvironmentVariable("BYK_FLATPAK_ARCH", switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
    });
    for (resources) |r| flatpak.addFileInput(b.path(r));
    flatpak_step.dependOn(&b.addInstallDirectory(.{ .source_dir = flatpak_dir, .install_dir = .prefix, .install_subdir = "pkg" }).step);

    // Typing into GTK3/GTK4 apps on a private headless GNOME Shell.
    const e2e = b.addRunArtifact(tool);
    e2e.addArgs(&.{ "wayland-e2e", root });
    e2e.addFileArg(ime.getEmittedBin());
    e2e.has_side_effects = true;
    e2e.step.dependOn(linux_step); // also compiles the GSettings schema it uses
    e2e.step.dependOn(wayland_e2e_step);
    e2e_step.dependOn(&e2e.step);

    // The built .deb in clean containers. The checker (`linux tested`) runs
    // inside them, so it is built static (musl): it must not need the host's glibc.
    // `-Dlinux-deb=` reuses an already-packaged .deb (cd/release) instead of
    // building another one via the package step.
    const external_deb = b.option([]const u8, "linux-deb", "Existing .deb (or dir) for `e2e -- linux-install`; skip re-packaging");
    const external_arch_pkg = b.option([]const u8, "linux-arch-pkg", "Existing Arch .pkg.tar.zst (or dir) for `e2e -- linux-install`; skip re-packaging");
    const static_tool = b.addExecutable(.{
        .name = "linux-static",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/linux.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = switch (arch) {
                    .x86_64 => .x86_64,
                    .aarch64 => .aarch64,
                },
                .os_tag = .linux,
                .abi = .musl,
            }),
            .optimize = .small,
        }),
    });
    const matrix = b.addRunArtifact(tool);
    matrix.addArg("install-matrix");
    matrix.addFileArg(ime_test.getEmittedBin());
    if (external_deb) |p| {
        matrix.addArg(p);
    } else {
        matrix.addDirectoryArg(deb_dir);
    }
    // Arch Linux has x86_64 images only, so the Arch package is tested there.
    if (external_arch_pkg) |p| {
        matrix.addArg(b.fmt("--arch-pkg={s}", .{p}));
    } else if (arch == .x86_64) {
        matrix.addPrefixedDirectoryArg("--arch-pkg=", arch_dir);
    }
    matrix.addPrefixedFileArg("--tool=", static_tool.getEmittedBin());
    matrix.addPrefixedFileArg("--icon-check=", icon_check.getEmittedBin());
    matrix.addPassthruArgs(); // optional docker images after `--`
    matrix.has_side_effects = true;
    matrix.step.dependOn(&install_ime_test.step);
    install_test_step.dependOn(&matrix.step);
}

/// The IBus engine, with its own static copy of the core so it is
/// self-contained whether or not -Dshared was passed (the .so is for packaging).
fn linuxIme(
    b: *std.Build,
    linux_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    sysroot: ?Sysroot,
) *std.Build.Step.Compile {
    const ime_core = b.addLibrary(.{
        .linkage = .static,
        .name = "byakaron_ime_core",
        .root_module = core,
    });

    const ime = b.addExecutable(.{
        .name = "byakaron-ibus",
        .root_module = b.createModule(.{
            .target = linux_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ime.root_module.addCSourceFiles(.{
        .files = &.{
            "apps/linux/Keyboard/main.c",
            "apps/linux/Keyboard/engine.c",
            "apps/linux/Core/spell.c",
            "apps/linux/Core/composer.c",
            "apps/linux/Core/prefs.c",
        },
        .flags = engine_cflags,
    });
    ime.root_module.addIncludePath(b.path("src/ffi"));
    ime.root_module.addIncludePath(b.path("apps/linux/Core"));
    ime.root_module.addIncludePath(b.path("apps/linux/Keyboard"));
    // Natively through pkg-config (`zig build linux-deps -- --test`).
    linkLinux(b, ime.root_module, sysroot, &.{ "ibus-1.0", "glib-2.0", "gobject-2.0", "gio-2.0" });
    ime.root_module.linkLibrary(ime_core);
    // Host libibus/libglib were built against this machine's glibc. Their
    // own undefined symbols (stat@GLIBC_2.33, etc.) must not be required
    // of our 2.31 libc stubs — at runtime each Ubuntu release loads its
    // own libibus, which matches its own libc.
    ime.linker_allow_shlib_undefined = true;
    return ime;
}

/// The GTK3 companion app. Built against the pinned sysroot like the engine,
/// so no libgtk-3-dev is required.
fn linuxApp(
    b: *std.Build,
    linux_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    sysroot: ?Sysroot,
    locale: LocaleStrings,
) *std.Build.Step.Compile {
    const app_core = b.addLibrary(.{
        .linkage = .static,
        .name = "byakaron_app_core",
        .root_module = core,
    });

    const app = b.addExecutable(.{
        .name = "byakaron",
        .root_module = b.createModule(.{
            .target = linux_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    app.root_module.addCSourceFiles(.{
        .files = &.{
            "apps/linux/App/main.c",
            "apps/linux/App/window.c",
            "apps/linux/App/spelling.c",
            "apps/linux/App/layout.c",
            "apps/linux/App/setup.c",
            "apps/linux/App/uiutil.c",
            "apps/linux/App/dictionary.c",
            "apps/linux/App/settings.c",
            "apps/linux/App/updates.c",
            "apps/linux/Core/spell.c",
            "apps/linux/Core/composer.c",
            "apps/linux/Core/prefs.c",
            "apps/linux/Core/update.c",
        },
        .flags = app_cflags,
    });
    app.root_module.addIncludePath(b.path("src/ffi"));
    app.root_module.addIncludePath(b.path("apps/linux/Core"));
    app.root_module.addIncludePath(b.path("apps/linux/App"));
    app.root_module.addIncludePath(locale.dir);
    app.root_module.addCMacro("BYK_APP_VERSION", "\"" ++ @import("build.zig.zon").version ++ "\"");
    linkLinux(b, app.root_module, sysroot, &.{ "gtk+-3.0", "glib-2.0", "gobject-2.0", "gio-2.0" });
    // Host libgtk was built against this machine's glibc. Same reason as
    // the engine: a 2.31-targeted binary must not require the host
    // library's newer undefined symbols.
    app.linker_allow_shlib_undefined = true;
    // Its own static copy of the core, like the engine above: two 7 MB
    // binaries beat one shared .so that needs a SONAME, an ldconfig
    // trigger and an ABI promise this version cannot make yet.
    app.root_module.linkLibrary(app_core);
    return app;
}

/// The Fcitx5 addon (C++ against the host's libFcitx5Core). The system's g++
/// compiles engine.cpp, not Zig: Fcitx5's API passes std::string and
/// std::function, every distribution builds Fcitx5 against libstdc++, and
/// Zig's C++ is libc++, so a Zig-built addon referenced std::__1 symbols that
/// no Fcitx5 has (7 undefined; it never loaded). Zig still builds the engine
/// and the C glue as static libraries with a C interface, and g++ links them
/// with --no-undefined: a missing symbol is now a build error, not a .so that
/// does not load.
fn linuxFcitx(
    b: *std.Build,
    linux_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) std.Build.LazyPath {
    const fcitx_core = b.addLibrary(.{
        .linkage = .static,
        .name = "byakaron_fcitx_core",
        .root_module = core,
    });
    fcitx_core.bundle_compiler_rt = true;
    fcitx_core.bundle_ubsan_rt = true;

    const glue = b.addLibrary(.{
        .linkage = .static,
        .name = "byakaron_fcitx_glue",
        .root_module = b.createModule(.{
            .target = linux_target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    glue.root_module.addCSourceFiles(.{
        .files = &.{
            "apps/linux/Core/composer.c",
            "apps/linux/Core/spell.c",
            "apps/linux/Core/prefs.c",
        },
        .flags = fcitx_cflags,
    });
    glue.root_module.addIncludePath(b.path("src/ffi"));
    glue.root_module.addIncludePath(b.path("apps/linux/Core"));
    addHostLibdir(b, glue.root_module);
    glue.root_module.linkSystemLibrary("glib-2.0", .{});
    glue.root_module.linkSystemLibrary("gio-2.0", .{});
    glue.bundle_ubsan_rt = true;

    // C++20: Fcitx5's headers on Ubuntu 26.04 use std::span and
    // string_view::starts_with. GLib 2.64: Ubuntu 20.04's, as for the engine.
    const gxx = b.addSystemCommand(&.{
        "sh",             "-c",
        \\set -e
        \\pkgs="Fcitx5Core glib-2.0 gio-2.0"
        \\g++ -std=c++20 -shared -fPIC $5 -Wall -Wextra -o "$4" "$1" \
        \\    -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_64 \
        \\    -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_64 \
        \\    -I"$6" -I"$7" -I"$8" $(pkg-config --cflags $pkgs) \
        \\    "$3" "$2" $(pkg-config --libs $pkgs) -lpthread -lm -ldl \
        \\    -Wl,--no-undefined
        ,
        "byakaron-fcitx",
    });
    gxx.addFileArg(b.path("apps/linux/Fcitx5/engine.cpp"));
    gxx.addFileArg(fcitx_core.getEmittedBin());
    gxx.addFileArg(glue.getEmittedBin());
    const so = gxx.addOutputFileArg("byakaron.so");
    gxx.addArg(if (optimize == .debug) "-O0 -g" else "-O2");
    gxx.addDirectoryArg(b.path("src/ffi"));
    gxx.addDirectoryArg(b.path("apps/linux/Core"));
    gxx.addDirectoryArg(b.path("apps/linux/Fcitx5"));
    gxx.addFileInput(b.path("apps/linux/Fcitx5/engine.h"));
    gxx.addFileInput(b.path("apps/linux/Core/composer.h"));
    gxx.addFileInput(b.path("src/ffi/byakaron.h"));
    return so;
}

const LinuxArch = enum { x86_64, aarch64 };

/// Xcode configurations: Debug, Release (non-sandboxed, auto-installs the
/// keyboard), Release-Sandboxed (sandboxed app, manual keyboard install).
const MacosConfig = enum { debug, release, sandboxed };

const Sysroot = struct {
    root: std.Build.LazyPath,
    /// Debian multiarch directory, e.g. `x86_64-linux-gnu`.
    triple: []const u8,
};

/// Ubuntu 24.04 headers + shared libraries for IBus, GLib and GTK 3, unpacked
/// from the packages pinned in src/build/linux_sysroot.zon. Each download is
/// keyed on its URL and SHA-256-checked, so it happens once per machine.
fn linuxSysroot(b: *std.Build, arch: LinuxArch) Sysroot {
    const Deb = struct { url: []const u8, sha256: []const u8 };
    const debs: struct { x86_64: []const Deb, aarch64: []const Deb } = @import("src/build/linux_sysroot.zon");

    const fetch = hostExe(b, "fetch", "src/build/fetch.zig");
    const unpack = b.addRunArtifact(hostExe(b, "linux_sysroot", "src/build/linux_sysroot.zig"));
    const root = unpack.addOutputDirectoryArg("sysroot");
    for (switch (arch) {
        .x86_64 => debs.x86_64,
        .aarch64 => debs.aarch64,
    }) |deb| {
        const run = b.addRunArtifact(fetch);
        run.addArg(deb.url);
        const out = run.addOutputFileArg(std.fs.path.basename(deb.url));
        run.addArg(deb.sha256);
        unpack.addFileArg(out);
    }
    return .{ .root = root, .triple = b.fmt("{t}-linux-gnu", .{arch}) };
}

/// Include dirs (sysroot-relative; `{triple}` is the multiarch dir) and libraries
/// for each pkg-config name the Linux build uses, matching Ubuntu 24.04's .pc files.
const LinuxPkg = struct { includes: []const []const u8, libs: []const []const u8 };
const linux_pkgs = std.StaticStringMap(LinuxPkg).initComptime(.{
    .{ "glib-2.0", LinuxPkg{ .includes = &.{ "usr/include/glib-2.0", "usr/lib/{triple}/glib-2.0/include" }, .libs = &.{"glib-2.0"} } },
    .{ "gobject-2.0", LinuxPkg{ .includes = &.{}, .libs = &.{"gobject-2.0"} } },
    .{ "gio-2.0", LinuxPkg{ .includes = &.{}, .libs = &.{"gio-2.0"} } },
    .{ "ibus-1.0", LinuxPkg{ .includes = &.{"usr/include/ibus-1.0"}, .libs = &.{"ibus-1.0"} } },
    .{ "gdk-pixbuf-2.0", LinuxPkg{ .includes = &.{"usr/include/gdk-pixbuf-2.0"}, .libs = &.{"gdk_pixbuf-2.0"} } },
    .{ "gtk+-3.0", LinuxPkg{
        .includes = &.{
            "usr/include/gtk-3.0",
            "usr/include/pango-1.0",
            "usr/include/harfbuzz",
            "usr/include/cairo",
            "usr/include/gdk-pixbuf-2.0",
            "usr/include/atk-1.0",
        },
        .libs = &.{ "gtk-3", "gdk-3", "pangocairo-1.0", "pango-1.0", "harfbuzz", "atk-1.0", "cairo-gobject", "cairo", "gdk_pixbuf-2.0" },
    } },
});

/// Link `pkgs` natively via pkg-config, or from the cross sysroot.
fn linkLinux(b: *std.Build, m: *std.Build.Module, sysroot: ?Sysroot, pkgs: []const []const u8) void {
    const s = sysroot orelse {
        addHostLibdir(b, m);
        for (pkgs) |pkg| m.linkSystemLibrary(pkg, .{});
        return;
    };
    m.addLibraryPath(s.root.path(b, b.fmt("usr/lib/{s}", .{s.triple})));
    for (pkgs) |pkg| {
        const info = linux_pkgs.get(pkg) orelse @panic(pkg);
        for (info.includes) |inc| {
            const sub = std.mem.replaceOwned(u8, b.allocator, inc, "{triple}", s.triple) catch @panic("OOM");
            m.addIncludePath(s.root.path(b, sub));
        }
        for (info.libs) |lib| m.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    }
    // gtk+-3.0 and ibus-1.0 pull in GLib's headers and libraries too.
    if (linux_pkgs.get("glib-2.0")) |glib| for (glib.includes) |inc| {
        const sub = std.mem.replaceOwned(u8, b.allocator, inc, "{triple}", s.triple) catch @panic("OOM");
        m.addIncludePath(s.root.path(b, sub));
    };
}

/// `app_opts` for a zx module used as a library (zx.Db, no zx.App server):
/// zx.App requires it even when only zx.Db is consumed.
fn zxLibraryOptions(b: *std.Build) *std.Build.Step.Options {
    const app_opts = b.addOptions();
    app_opts.addOption(?[]const u8, "app_base_path", null);
    app_opts.addOption(?u16, "server_port", null);
    app_opts.addOption(?[]const u8, "server_address", null);
    app_opts.addOption([]const u8, "cli_command", "--");
    app_opts.addOption(bool, "enable_httpz", false);
    app_opts.addOption(bool, "feat_sqlite_server", false);
    app_opts.addOption(bool, "feat_pg_server", false);
    app_opts.addOption(bool, "feat_kv_server", false);
    app_opts.addOption(bool, "feat_kv_client", false);
    app_opts.addOption(bool, "feat_cache_server", false);
    return app_opts;
}

/// src/build/sql.zig over a host-target zx with SQLite (ziex bundles it), for
/// the host build tools.
fn hostSqlModule(b: *std.Build) *std.Build.Module {
    const zx_mod = b.dependency("ziex", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .lsp = false,
        .@"feature-sqlite" = true,
    }).module("zx");
    zx_mod.addOptions("app_opts", zxLibraryOptions(b));
    return b.createModule(.{
        .root_source_file = b.path("src/build/sql.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zx", .module = zx_mod }},
    });
}

fn hostExe(b: *std.Build, name: []const u8, root: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
}

fn androidNdk(b: *std.Build) ?[]const u8 {
    if (b.option([]const u8, "android-ndk", "Android NDK directory for the Android steps")) |p| return p;
    const env = &b.graph.environ_map;
    for ([_][]const u8{ "ANDROID_NDK_ROOT", "ANDROID_NDK_HOME" }) |name| {
        if (env.get(name)) |p| if (p.len > 0) return p;
    }
    return installedNdk(b) orelse fetchedNdk(b);
}

/// The NDK package from build.zig.zon (lazy: downloaded only when no local NDK
/// was found). Its sysroot is all the Android libraries need. It is the macOS
/// NDK, so other hosts never fetch it (every build would otherwise download
/// it, `deps -- linux` included).
fn fetchedNdk(b: *std.Build) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const dep = b.lazyDependency("ndk", .{}) orelse return null;
    return rootPath(dep.builder, ".");
}

fn installedNdk(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const ndk_root = b.pathJoin(&.{ androidSdk(b) orelse return null, "ndk" });
    var dir = std.Io.Dir.cwd().openDir(io, ndk_root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var newest: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const v = std.SemanticVersion.parse(entry.name) catch continue;
        if (newest) |n| if (std.SemanticVersion.parse(n) catch null) |nv| if (v.order(nv) != .gt) continue;
        newest = b.dupe(entry.name);
    }
    return if (newest) |n| b.pathJoin(&.{ ndk_root, n }) else null;
}

fn androidSdk(b: *std.Build) ?[]const u8 {
    const env = &b.graph.environ_map;
    return firstDir(b, &.{
        env.get("ANDROID_HOME"),
        env.get("ANDROID_SDK_ROOT"),
        envPath(b, "HOME", "Library/Android/sdk"),
        envPath(b, "HOME", "Android/Sdk"),
        envPath(b, "LOCALAPPDATA", "Android/Sdk"),
    });
}

fn androidStudioJdk(b: *std.Build) ?[]const u8 {
    return firstDir(b, &.{
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        envPath(b, "HOME", "android-studio/jbr"),
        "/opt/android-studio/jbr",
        envPath(b, "ProgramFiles", "Android/Android Studio/jbr"),
    });
}

fn envPath(b: *std.Build, name: []const u8, sub: []const u8) ?[]const u8 {
    return b.pathJoin(&.{ b.graph.environ_map.get(name) orelse return null, sub });
}

fn firstDir(b: *std.Build, paths: []const ?[]const u8) ?[]const u8 {
    for (paths) |path| {
        const p = path orelse continue;
        if (p.len == 0) continue;
        var dir = std.Io.Dir.cwd().openDir(b.graph.io, p, .{}) catch continue;
        dir.close(b.graph.io);
        return p;
    }
    return null;
}

/// iOS keyboard (apps/ios/keyboard, the byakaron-ios submodule): the engine as
/// Byakaron.xcframework (device + simulator static libraries, byakaron.h and
/// byakaron_strings.h with a `Byakaron` module map) for its Xcode project.
///   zig build ios              → zig-out/bin/Byakaron-ios.app (simulator, unsigned),
///                                and zig-out/lib/ios/Byakaron.xcframework for Xcode
///   zig build dev -- ios       → install and launch it on the booted simulator
///   zig build e2e -- ios [...] → KeyboardUITests on an iPhone x iOS matrix (src/build/ios_e2e.zig)
///   zig build gen -- ios-settings | ios-emoji
fn addIos(b: *std.Build, cli: *Cli, avro: AvroData, locale: LocaleStrings) void {
    // Not a named step: `ios` and `e2e -- ios` run it. Builds the engine as
    // zig-out/lib/ios/Byakaron.xcframework.
    const step = &b.addWriteFiles().step;
    const ios = b.step("ios", "Build the iOS keyboard for the simulator (unsigned) → zig-out/bin/Byakaron-ios.app");
    const dev = cli.dev.add(b, "ios", "Install and launch the iOS app on the booted simulator");
    const e2e = cli.e2e.add(b, "ios", "KeyboardUITests on an iPhone x iOS simulator matrix (--list, --devices, --os, -j…)");
    const headers = b.addWriteFiles();
    _ = headers.addCopyFile(b.path("src/ffi/byakaron.h"), "byakaron.h");
    _ = headers.addCopyFile(locale.header, "byakaron_strings.h");
    _ = headers.add("module.modulemap",
        \\module Byakaron {
        \\    header "byakaron.h"
        \\    header "byakaron_strings.h"
        \\    export *
        \\}
        \\
    );
    // Assembled by hand: `xcodebuild -create-xcframework` reads the platform
    // from the library, and Zig's archives carry none, so on some Xcode
    // versions it files the simulator slice under ios-arm64 too and fails.
    // Args: out, then (library, headers) for the device and the simulator.
    const xcf = b.addSystemCommand(&.{ "sh", "-c",
        \\out="$1/Byakaron.xcframework"; mkdir -p "$out/ios-arm64" "$out/ios-arm64_x86_64-simulator"
        \\cp "$2" "$out/ios-arm64/libbyakaron.a"; cp -R "$3" "$out/ios-arm64/Headers"
        \\cp "$4" "$out/ios-arm64_x86_64-simulator/libbyakaron.a"; cp -R "$5" "$out/ios-arm64_x86_64-simulator/Headers"
        \\cat > "$out/Info.plist" <<'PLIST'
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\<key>AvailableLibraries</key><array>
        \\<dict><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>ios-arm64</string><key>LibraryPath</key><string>libbyakaron.a</string><key>SupportedArchitectures</key><array><string>arm64</string></array><key>SupportedPlatform</key><string>ios</string></dict>
        \\<dict><key>HeadersPath</key><string>Headers</string><key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string><key>LibraryPath</key><string>libbyakaron.a</string><key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array><key>SupportedPlatform</key><string>ios</string><key>SupportedPlatformVariant</key><string>simulator</string></dict>
        \\</array><key>CFBundlePackageType</key><string>XFWK</string><key>XCFrameworkFormatVersion</key><string>1.0</string></dict></plist>
        \\PLIST
        \\
        , "sh" });
    const xcf_dir = xcf.addOutputDirectoryArg("xcf");
    // iOS 27: the keyboard's deployment target (apps/ios/keyboard).
    const ios_min: std.Target.Query.OsVersion = .{ .semver = .{ .major = 27, .minor = 0, .patch = 0 } };
    const lib = struct {
        fn build(bb: *std.Build, av: AvroData, q: std.Target.Query) std.Build.LazyPath {
            // ReleaseFast, as for macOS: Xcode's linker has no UBSan runtime.
            const engine = addEngine(bb, bb.resolveTargetQuery(q), .ReleaseFast, av, false);
            const l = bb.addLibrary(.{ .linkage = .static, .name = "byakaron", .root_module = engine.root });
            l.bundle_compiler_rt = true;
            return l.getEmittedBin();
        }
    }.build;
    const device = lib(b, avro, .{ .cpu_arch = .aarch64, .os_tag = .ios, .os_version_min = ios_min });
    // One simulator library for Apple silicon and Intel Macs.
    const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
    lipo.addFileArg(lib(b, avro, .{ .cpu_arch = .aarch64, .os_tag = .ios, .abi = .simulator, .os_version_min = ios_min }));
    lipo.addFileArg(lib(b, avro, .{ .cpu_arch = .x86_64, .os_tag = .ios, .abi = .simulator, .os_version_min = ios_min }));
    lipo.addArg("-output");
    const simulator = lipo.addOutputFileArg("libbyakaron.a");
    for ([_]std.Build.LazyPath{ device, simulator }) |path| {
        xcf.addFileArg(path);
        xcf.addDirectoryArg(headers.getDirectory());
    }
    const out = xcf_dir.path(b, "Byakaron.xcframework");
    step.dependOn(&b.addInstallDirectory(.{ .source_dir = out, .install_dir = .lib, .install_subdir = "ios/Byakaron.xcframework" }).step);

    // The app's Settings.bundle, from the settings manifest
    // (src/build/settings_bundle.zig). Committed in the submodule, so Xcode
    // alone builds the app; `ios` and `gen -- ios-settings` refresh it.
    const settings_gen = hostExe(b, "settings_bundle", "src/build/settings_bundle.zig");
    settings_gen.root_module.addImport("settings", b.createModule(.{
        .root_source_file = b.path("src/settings.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    const settings_dir = b.addRunArtifact(settings_gen).addOutputDirectoryArg("Settings.bundle");
    const settings_bundle = b.addUpdateSourceFiles();
    for ([_][]const u8{ "Root.plist", "en.lproj/Root.strings", "bn.lproj/Root.strings" }) |file| {
        settings_bundle.addCopyFileToSource(settings_dir.path(b, file), b.fmt("apps/ios/keyboard/HostingApp/Settings.bundle/{s}", .{file}));
    }
    cli.gen.add(b, "ios-settings", "The iOS app's Settings.bundle from the settings manifest").dependOn(&settings_bundle.step);

    // The emoji picker's list (Keyboard/Models/EmojiData.swift) from Unicode's
    // emoji-test.txt, which the Android keyboard's checkout carries.
    {
        const run = b.addRunArtifact(hostExe(b, "ios_emoji", "src/build/ios_emoji.zig"));
        run.addFileArg(b.path("apps/android/keyboard/tools/make-emoji-keys/src/main/resources/emoji/ucd/17.0/emoji-test.txt"));
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(run.addOutputFileArg("EmojiData.swift"), "apps/ios/keyboard/Keyboard/Models/EmojiData.swift");
        cli.gen.add(b, "ios-emoji", "The iOS emoji picker's EmojiData.swift from Unicode's emoji-test.txt").dependOn(&update.step);
    }

    const keyboard = rootPath(b, "apps/ios/keyboard");
    const missing: ?[]const u8 = if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ keyboard, "GiellaKeyboard.xcworkspace" }), .{})) |_|
        if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ keyboard, "Pods/Manifest.lock" }), .{})) |_| null else |_| "CocoaPods are not installed: run `pod install` in apps/ios/keyboard"
    else |_|
        "apps/ios/keyboard is not checked out: git submodule update --init apps/ios/keyboard";
    if (missing) |why| {
        for ([_]*std.Build.Step{ ios, dev, e2e }) |s| s.dependOn(&b.addFail(why).step);
        return;
    }
    step.dependOn(&settings_bundle.step);
    // The app embeds the keyboard extension. Unsigned simulator build; Xcode
    // tracks its own inputs, so it always runs.
    const xcb = b.addSystemCommand(&.{
        "sh", "-c",
        \\out=$1; dd=$2; kb=$3
        \\mkdir -p "$dd" "$out" && dd=$(cd "$dd" && pwd) && out=$(cd "$out" && pwd)
        \\cd "$kb" && xcodebuild -workspace GiellaKeyboard.xcworkspace -scheme HostingApp -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet build >"$dd/build.log" 2>&1 || { grep -E "error:" "$dd/build.log" | sort -u | head -30; echo "full log: $dd/build.log"; exit 1; }
        \\cp -R "$dd/Build/Products/Debug-iphonesimulator/HostingApp.app" "$out/Byakaron-ios.app"
        ,
        "sh",
    });
    const app_out = xcb.addOutputDirectoryArg("app");
    xcb.addDirectoryArg(b.graph.path(.local_cache, "xcode/ios"));
    xcb.addArg(keyboard);
    xcb.has_side_effects = true;
    xcb.step.dependOn(step);
    const install_app = b.addInstallDirectory(.{ .source_dir = app_out, .install_dir = .prefix, .install_subdir = "bin" });
    ios.dependOn(&install_app.step);

    // Onto the booted simulator (Simulator.app opens one if none is).
    const launch = b.addSystemCommand(&.{ "sh", "-c",
        \\app=$1
        \\xcrun simctl list devices booted | grep -q Booted || { echo "no booted simulator: open Simulator.app (or xcrun simctl boot <device>)"; exit 1; }
        \\id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
        \\xcrun simctl install booted "$app" && xcrun simctl launch booted "$id"
        , "sh" });
    launch.addDirectoryArg(b.graph.path(.install_prefix, "bin/Byakaron-ios.app"));
    launch.has_side_effects = true;
    launch.step.dependOn(&install_app.step);
    dev.dependOn(&launch.step);

    // The tool builds the app and its UI tests itself (xcodebuild
    // build-for-testing, or --products from an earlier build).
    const e2e_run = b.addRunArtifact(hostExe(b, "ios_e2e", "src/build/ios_e2e.zig"));
    e2e_run.addArg(keyboard);
    e2e_run.addPassthruArgs();
    e2e_run.has_side_effects = true;
    e2e_run.step.dependOn(step);
    e2e.dependOn(&e2e_run.step);
}

/// Android keyboard (apps/android/keyboard, the byakaron-android submodule):
///   zig build android          → zig-out/bin/Byakaron-debug.apk
///   zig build dev -- android   → install it on the connected device and open it
///   zig build pack -- android  → release build with Byakaron.db → zig-out/pkg/Byakaron.apk + Byakaron.aab
fn addAndroid(b: *std.Build, cli: *Cli, avro: AvroData, spell_db: std.Build.LazyPath, locale: LocaleStrings) void {
    // Not a named step: the app steps below run it. Builds libbyakaron.so for
    // every ABI → zig-out/lib/android/jniLibs + the keyboard's jniLibs.
    const step = &b.addWriteFiles().step;
    const app_steps = [_]*std.Build.Step{
        b.step("android", "Build the Android keyboard (debug) → zig-out/bin/Byakaron-debug.apk"),
        cli.dev.add(b, "android", "Install the debug keyboard on the connected device and open it"),
        cli.pack.add(b, "android", "Release build with Byakaron.db → zig-out/pkg/Byakaron.apk + Byakaron.aab"),
    };
    for (app_steps) |s| s.dependOn(step);
    // The shared labels as R.string.byakaron_* (used for the settings the Zig
    // composer implements, settings/screens/TextCorrectionScreen.kt). Written
    // into the keyboard checkout and committed there, so Android Studio builds
    // have them too.
    {
        const strings = b.addUpdateSourceFiles();
        for (localeFiles()) |f| {
            const dir = if (std.mem.eql(u8, f.code, "en")) "values" else b.fmt("values-{s}", .{f.code});
            strings.addCopyFileToSource(
                locale.android.path(b, b.fmt("{s}/byakaron_strings.xml", .{dir})),
                b.fmt("apps/android/keyboard/app/src/main/res/{s}/byakaron_strings.xml", .{dir}),
            );
        }
        step.dependOn(&strings.step);
    }
    const api = b.option(u32, "android-api", "Minimum Android API level for the Android steps (default 21)") orelse 21;
    const ndk = androidNdk(b) orelse {
        step.dependOn(&b.addFail("Android NDK not found: pass -Dandroid-ndk=<dir> or set ANDROID_NDK_ROOT").step);
        return;
    };
    const host_tag = switch (builtin.os.tag) {
        .macos => "darwin-x86_64", // the NDK ships one universal darwin toolchain
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    const sysroot = b.pathJoin(&.{ ndk, "toolchains/llvm/prebuilt", host_tag, "sysroot" });

    const abis = [_]struct { abi: []const u8, arch: std.Target.Cpu.Arch, abi_tag: std.Target.Abi, triple: []const u8 }{
        .{ .abi = "arm64-v8a", .arch = .aarch64, .abi_tag = .android, .triple = "aarch64-linux-android" },
        .{ .abi = "armeabi-v7a", .arch = .arm, .abi_tag = .androideabi, .triple = "arm-linux-androideabi" },
        .{ .abi = "x86_64", .arch = .x86_64, .abi_tag = .android, .triple = "x86_64-linux-android" },
    };
    const update = b.addUpdateSourceFiles();
    for (abis) |a| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = a.arch,
            .os_tag = .linux,
            .abi = a.abi_tag,
            .android_api_level = api,
        });
        const crt = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, a.triple, api });
        const libc = b.addWriteFiles().add(b.fmt("libc-{s}.txt", .{a.abi}), b.fmt(
            \\include_dir={s}/usr/include
            \\sys_include_dir={s}/usr/include/{s}
            \\crt_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\cc_dir={s}
            \\darwin_sdk_dir=
            \\
        , .{ sysroot, sysroot, a.triple, crt, crt }));

        const engine = addEngine(b, target, .ReleaseFast, avro, false);
        engine.root.strip = true;
        const lib = b.addLibrary(.{ .linkage = .dynamic, .name = "byakaron", .root_module = engine.root });
        lib.setLibCFile(libc);
        const out = b.fmt("lib/android/jniLibs/{s}/libbyakaron.so", .{a.abi});
        step.dependOn(&b.addInstallFileWithDir(lib.getEmittedBin(), .prefix, out).step);
        update.addCopyFileToSource(lib.getEmittedBin(), b.fmt("apps/android/keyboard/app/src/main/jniLibs/{s}/libbyakaron.so", .{a.abi}));
    }
    step.dependOn(&update.step);

    // Gradle tracks its own inputs, so it always runs.
    const keyboard = rootPath(b, "apps/android/keyboard");
    std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ keyboard, "gradlew" }), .{}) catch {
        const fail = b.addFail("apps/android/keyboard is not checked out: git submodule update --init apps/android/keyboard");
        for (app_steps) |s| s.dependOn(&fail.step);
        return;
    };
    const gradle_exe = hostExe(b, "gradle", "src/build/gradle.zig");
    const gradle = struct {
        fn run(bb: *std.Build, exe: *std.Build.Step.Compile, project: []const u8, task: []const u8, libs: *std.Build.Step) *std.Build.Step.Run {
            const r = bb.addRunArtifact(exe);
            r.addArgs(&.{ project, task });
            r.has_side_effects = true;
            r.step.dependOn(libs);
            const env = &bb.graph.environ_map;
            if (env.get("ANDROID_HOME") == null) if (androidSdk(bb)) |sdk| r.setEnvironmentVariable("ANDROID_HOME", sdk);
            if (env.get("JAVA_HOME") == null) if (androidStudioJdk(bb)) |jdk| r.setEnvironmentVariable("JAVA_HOME", jdk);
            return r;
        }
    }.run;

    const debug = gradle(b, gradle_exe, keyboard, ":app:assembleDebug", step);
    debug.addArg(b.pathJoin(&.{ keyboard, "app/build/outputs/apk/debug" }));
    const debug_apk = debug.addOutputFileArg("Byakaron-debug.apk");
    app_steps[0].dependOn(&b.addInstallFileWithDir(debug_apk, .prefix, "bin/Byakaron-debug.apk").step);

    // installDebug, then open the app (its settings) on the device.
    const install = gradle(b, gradle_exe, keyboard, ":app:installDebug", step);
    const open = b.addSystemCommand(&.{ "sh", "-c",
        \\adb=adb; [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ] && adb="$ANDROID_HOME/platform-tools/adb"
        \\"$adb" shell monkey -p com.nuhulabs.byakaron.debug -c android.intent.category.LAUNCHER 1 >/dev/null
        , "sh" });
    if (b.graph.environ_map.get("ANDROID_HOME") == null) if (androidSdk(b)) |sdk| open.setEnvironmentVariable("ANDROID_HOME", sdk);
    open.has_side_effects = true;
    open.step.dependOn(&install.step);
    app_steps[1].dependOn(&open.step);

    const assets = b.addUpdateSourceFiles();
    assets.addCopyFileToSource(spell_db, "apps/android/keyboard/app/src/main/assets/byakaron/Byakaron.db");

    // Sideload APK + Play Store AAB (bundleRelease). Both share Byakaron.db assets.
    const release_apk_run = gradle(b, gradle_exe, keyboard, ":app:assembleRelease", step);
    release_apk_run.step.dependOn(&assets.step);
    release_apk_run.addArg(b.pathJoin(&.{ keyboard, "app/build/outputs/apk/release" }));
    const release_apk = release_apk_run.addOutputFileArg("Byakaron.apk");
    app_steps[2].dependOn(&b.addInstallFileWithDir(release_apk, .prefix, "pkg/Byakaron.apk").step);

    const release_aab_run = gradle(b, gradle_exe, keyboard, ":app:bundleRelease", step);
    release_aab_run.step.dependOn(&assets.step);
    release_aab_run.addArg(b.pathJoin(&.{ keyboard, "app/build/outputs/bundle/release" }));
    const release_aab = release_aab_run.addOutputFileArg("Byakaron.aab");
    app_steps[2].dependOn(&b.addInstallFileWithDir(release_aab, .prefix, "pkg/Byakaron.aab").step);
}

/// What src/build/locale.zig generates from src/locale/*.zon.
const LocaleStrings = struct {
    /// The directory holding `byakaron_strings.h`, for include paths.
    dir: std.Build.LazyPath,
    header: std.Build.LazyPath,
    /// `Strings.zig`, the web app's `strings` module.
    zig: std.Build.LazyPath,
    /// `values[-<code>]/byakaron_strings.xml`.
    android: std.Build.LazyPath,
};

fn localeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/locale/Locale.zig"), .target = target, .optimize = optimize });
}

fn localeFiles() []const @import("src/locale/Locale.zig").File {
    return &@import("src/locale/Locale.zig").files;
}

fn localeStrings(b: *std.Build) LocaleStrings {
    const gen = hostExe(b, "locale", "src/build/locale.zig");
    gen.root_module.addImport("locale", localeModule(b, b.graph.host, .Debug));
    const run = b.addRunArtifact(gen);
    const dir = run.addOutputDirectoryArg("strings");
    return .{
        .dir = dir,
        .header = dir.path(b, "byakaron_strings.h"),
        .zig = dir.path(b, "Strings.zig"),
        .android = dir.path(b, "android"),
    };
}

/// iAvro's data: the committed lexicon.zon (src/build/lexicon.zig resyncs it) and what lexicon_files.zig derives from it.
const AvroData = struct {
    words: std.Build.LazyPath,
    json: std.Build.LazyPath,
    /// AutoComplete/Mem.zig's compiled-in dictionary, suffix and autocorrect tables.
    lexicon: std.Build.LazyPath,
};

/// The committed lexicon.zon, plus the word list and Dictionary.json derived from it.
fn avroDictionary(b: *std.Build) AvroData {
    const lexicon = b.path("src/AutoComplete/lexicon.zon");
    const gen = hostExe(b, "lexicon_files", "src/build/lexicon_files.zig");
    gen.root_module.addImport("lexicon_type", b.createModule(.{ .root_source_file = b.path("src/AutoComplete/Lexicon.zig") }));
    const run = b.addRunArtifact(gen);
    run.addFileArg(lexicon);
    return .{
        .words = run.addOutputFileArg("avro_dictionary.txt"),
        .json = run.addOutputFileArg("Dictionary.json"),
        .lexicon = lexicon,
    };
}

/// Wikipedia → Byakaron.db, one cached Run step per stage:
///
///   fetch ─→ bnwiki-*.xml.bz2 ─data→ sentences.csv ─data --wordtriplets→ word_triplets.csv
///     ─export→ export/ + export_id/ ─prepare (+ Avro words, zx.Db)→ Byakaron.db
///
/// Only the steps a requested artifact needs run, and each re-runs only when its
/// inputs (tool binary, args, input files) change.
fn addSpellDb(
    b: *std.Build,
    host_sql: *std.Build.Module,
    avro_words: std.Build.LazyPath,
) struct { db: std.Build.LazyPath, debug_db: std.Build.LazyPath } {
    const config: struct { wiki_date: []const u8, revision: u32 } = @import("src/data/db.zon");
    const wiki_date = b.option([]const u8, "wiki-date", "bnwiki dump date for `gen -- db` (YYYYMMDD, default: src/data/db.zon)") orelse config.wiki_date;
    const wiki_dump = b.option(std.Build.LazyPath, "wiki-dump", "Use a local bnwiki pages-articles .xml/.xml.bz2 instead of downloading");

    const host = b.graph.host;
    const tokenization = b.createModule(.{
        .root_source_file = b.path("src/tokenization/tokenizer.zig"),
        .target = host,
        .optimize = .ReleaseFast,
    });
    const data = hostExe(b, "data", "src/data/main.zig");
    data.root_module.addImport("tokenization", tokenization);
    data.root_module.addImport("xml", b.dependency("xml", .{ .target = host, .optimize = .ReleaseFast }).module("xml"));
    data.root_module.linkLibrary(b.dependency("bzip2", .{ .target = host, .optimize = .ReleaseFast }).artifact("bz"));
    const export_exe = hostExe(b, "export", "src/data/export.zig");
    const prepare = hostExe(b, "prepare", "src/data/prepare.zig");
    prepare.root_module.addImport("sql", host_sql);

    const dump = wiki_dump orelse blk: {
        const name = b.fmt("bnwiki-{s}-pages-articles.xml.bz2", .{wiki_date});
        const run = b.addRunArtifact(hostExe(b, "fetch", "src/build/fetch.zig"));
        run.addArg(b.fmt("https://dumps.wikimedia.org/bnwiki/{s}/{s}", .{ wiki_date, name }));
        break :blk run.addOutputFileArg(name);
    };

    const sentences = blk: {
        const run = b.addRunArtifact(data);
        run.addFileArg(dump);
        run.addArg("--out");
        break :blk run.addOutputFileArg("sentences.csv");
    };
    const triplets = blk: {
        const run = b.addRunArtifact(data);
        run.addArg("--wordtriplets");
        run.addFileArg(sentences);
        run.addArg("--out");
        break :blk run.addOutputFileArg("word_triplets.csv");
    };
    const exported = blk: {
        const run = b.addRunArtifact(export_exe);
        run.addFileArg(triplets);
        run.addArg("--export-dir");
        const debug_dir = run.addOutputDirectoryArg("export");
        run.addArg("--export-id-dir");
        break :blk .{ .debug = debug_dir, .id = run.addOutputDirectoryArg("export_id") };
    };

    const assemble = struct {
        fn run(
            bb: *std.Build,
            prepare_exe: *std.Build.Step.Compile,
            data_exe: *std.Build.Step.Compile,
            schema: []const u8,
            export_dir: std.Build.LazyPath,
            words: std.Build.LazyPath,
            debug: bool,
            out: []const u8,
        ) std.Build.LazyPath {
            const r = bb.addRunArtifact(prepare_exe);
            r.addArg("--data");
            r.addArtifactArg(data_exe);
            r.addArg("--schema");
            r.addFileArg(bb.path(schema));
            r.addArg("--export");
            r.addDirectoryArg(export_dir);
            r.addArg("--seed");
            r.addFileArg(bb.path("src/data/queries/confusions_seed.csv"));
            r.addArg("--avro");
            r.addFileArg(words);
            if (debug) r.addArg("--debug");
            r.addArg("--work");
            _ = r.addOutputDirectoryArg("work");
            r.addArg("--out");
            return r.addOutputFileArg(out);
        }
    }.run;

    return .{
        .db = assemble(b, prepare, data, "src/data/queries/10_sqlite_schema_id.sql", exported.id, avro_words, false, "Byakaron.db"),
        .debug_db = assemble(b, prepare, data, "src/data/queries/07_sqlite_schema.sql", exported.debug, avro_words, true, "spell_debug.db"),
    };
}

fn trimSpellDb(b: *std.Build, tool: *std.Build.Step.Compile, db: std.Build.LazyPath, words: u32) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("trim");
    run.addFileArg(db);
    run.addArg(b.fmt("{d}", .{words}));
    return run.addOutputFileArg("Byakaron.db");
}

/// The Byakaron.db an app package ships (`spell_db pack`): same answers, ~45%
/// smaller. zig-out/db/ keeps the original, which `trim` and `d1` need.
fn packSpellDb(b: *std.Build, tool: *std.Build.Step.Compile, db: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("pack");
    run.addFileArg(db);
    return run.addOutputFileArg("Byakaron.db");
}

/// Absolute path to a file/dir relative to the build root (dir with build.zig).
fn rootPath(b: *std.Build, sub: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub) catch @panic("OOM");
}
