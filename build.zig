const std = @import("std");

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
    {
        const macos_step = b.step("macos", "Build macOS app");
        macos_step.dependOn(&run_cmd.step);
        // TODO: from platforms/macos/scripts/build.sh translate those to zig build steps
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
