const std = @import("std");
const ziex = @import("ziex");

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Shared Bangla tokenizer (from byakaron; no libc, wasm-safe) ---
    const byakaron_dep = b.dependency("byakaron", .{
        .target = target,
        .optimize = optimize,
    });
    const tokenization_mod = byakaron_dep.module("tokenization");
    const spell_mod = byakaron_dep.module("spell");

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
            },
        }),
    });

    // --- Ziex setup: wires dependencies and adds `zx`/`dev` build steps ---
    var ziex_b = try ziex.init(b, app_exe, .{ .app = .{ .features = .{
        .sqlite = .enabled,
        .kv = .enabled,
    } } });
    ziex_b = ziex_b; // ignore unused

    // Ship the optimized spell lexicon as the app sqlite file.
    const spell_db = b.addInstallFile(
        b.path("../../packages/data/spell.db"),
        "data/db/default.db",
    );
    b.getInstallStep().dependOn(&spell_db.step);
}
