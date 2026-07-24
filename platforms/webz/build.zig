const std = @import("std");
const ziex = @import("ziex");

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Shared Bangla engines from byakaron `src/` (wasm-safe cores) ---
    const byakaron_dep = b.dependency("byakaron", .{
        .target = target,
        .optimize = optimize,
    });
    const tokenization_mod = byakaron_dep.module("tokenization");
    const spell_mod = byakaron_dep.module("spell");
    const autocomplete_mod = byakaron_dep.module("autocomplete");

    // --- Ziex App Executable ---
    const app_exe = b.addExecutable(.{
        .name = "ziex_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tokenization", .module = tokenization_mod },
                .{ .name = "spell", .module = spell_mod },
                .{ .name = "autocomplete", .module = autocomplete_mod },
            },
        }),
    });

    // --- Ziex setup: wires dependencies and adds `zx`/`dev` build steps ---
    const ziex_b = try ziex.init(b, app_exe, .{ .app = .{ .features = .{
        .sqlite = .enabled,
        .kv = .enabled,
    } } });

    // SQLite / Mem backends from byakaron `src/`, bound to *this* app's `zx`
    // module so they share the same `zx.Db` type as `zx.db`.
    const spell_sqlite_mod = b.createModule(.{
        .root_source_file = b.path("../../src/Spell/Sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spell", .module = spell_mod },
            .{ .name = "zx", .module = ziex_b.zx_module },
        },
    });
    const autocomplete_sqlite_mod = b.createModule(.{
        .root_source_file = b.path("../../src/AutoComplete/Sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "autocomplete", .module = autocomplete_mod },
            .{ .name = "zx", .module = ziex_b.zx_module },
        },
    });
    const autocomplete_mem_mod = b.createModule(.{
        .root_source_file = b.path("../../src/AutoComplete/Mem.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "autocomplete", .module = autocomplete_mod },
        },
    });

    ziex_b.addImport("spell_sqlite", spell_sqlite_mod);
    ziex_b.addImport("autocomplete_sqlite", autocomplete_sqlite_mod);
    ziex_b.addImport("autocomplete_mem", autocomplete_mem_mod);

    // Ship the optimized spell lexicon as the app sqlite file.
    const spell_db = b.addInstallFile(
        b.path("../../packages/data/spell.db"),
        "data/db/default.db",
    );
    b.getInstallStep().dependOn(&spell_db.step);
}
