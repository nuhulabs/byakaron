const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml_dep = b.dependency("xml", .{});
    const bykaron_dep = b.dependency("byakaron", .{});
    const xml_mod = xml_dep.module("xml");
    const bykaron_mod = bykaron_dep.module("byakaron");
    const mod = b.addModule("data", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "data", .module = mod },
                .{ .name = "xml", .module = xml_mod },
                .{ .name = "byakaron", .module = bykaron_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Fast aggregations: word_triplets.csv → export/ + export_id/
    const export_exe = b.addExecutable(.{
        .name = "export",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(export_exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const export_step = b.step("export", "Aggregate word_triplets.csv → export/ + export_id/ CSVs");
    const export_run = b.addRunArtifact(export_exe);
    export_run.setCwd(b.path("."));
    export_run.addPassthruArgs();
    export_step.dependOn(&export_run.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // export → SymSpell + sqlite3 assemble → spell.db + spell_debug.db
    const prepare_step = b.step(
        "prepare",
        "Export triplets then assemble spell.db + spell_debug.db (needs sqlite3)",
    );
    const prepare_run = b.addSystemCommand(&.{"bash"});
    prepare_run.setCwd(b.path("."));
    prepare_run.addFileArg(b.path("src/queries/prepare_spell_dbs.sh"));
    prepare_run.addArtifactArg(exe);
    prepare_run.step.dependOn(&export_run.step);
    prepare_step.dependOn(&prepare_run.step);
}
