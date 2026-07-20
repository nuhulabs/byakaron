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

    const export_exe = b.addExecutable(.{
        .name = "export",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(export_exe);

    const prepare_exe = b.addExecutable(.{
        .name = "prepare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prepare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.installArtifact(prepare_exe);

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

    // prepare does NOT re-run export (export is slow). Run `zig build export` first when CSVs are stale.
    // Default: merge dictionary_macos.csv (Avro). Opt out: zig build prepare -- --no-avro
    const prepare_step = b.step(
        "prepare",
        "Assemble spell.db from export_id/ (+ Avro by default); --no-avro / --debug-db",
    );
    const prepare_run = b.addRunArtifact(prepare_exe);
    prepare_run.setCwd(b.path("."));
    prepare_run.addArtifactArg(exe);
    prepare_run.addPassthruArgs();
    prepare_step.dependOn(&prepare_run.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
