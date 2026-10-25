//! Build-time driver for the Android keyboard's Gradle build, run by
//! `zig build android` / `release-android` / `install-android`.
//!
//!   gradle <project> <task> [<apk-dir> <out.apk>]
//!
//! Runs `<project>/gradlew <task>` (gradlew.bat on Windows) quietly, so only
//! Gradle's warnings and errors show. With `<apk-dir>`, the one APK the task
//! left there (`Byakaron_<version>-<variant>.apk`) is copied to `<out.apk>`,
//! which the build installs into zig-out/android/.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 5) {
        std.debug.print("usage: {s} <project> <task> [<apk-dir> <out.apk>]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const project, const task = .{ args[1], args[2] };
    const gradlew = if (builtin.os.tag == .windows) "gradlew.bat" else "./gradlew";
    const cwd = Io.Dir.cwd();

    // An APK from an earlier version would sit next to the new one.
    if (args.len == 5) {
        var dir: ?Io.Dir = cwd.openDir(io, args[3], .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (dir) |*d| {
            defer d.close(io);
            var old: std.ArrayList([]const u8) = .empty;
            var it = d.iterate();
            while (try it.next(io)) |e| {
                if (e.kind == .file and std.mem.endsWith(u8, e.name, ".apk")) try old.append(arena, try arena.dupe(u8, e.name));
            }
            for (old.items) |name| try d.deleteFile(io, name);
        }
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ gradlew, "--quiet", "--console=plain", task },
        .cwd = .{ .path = project },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            std.debug.print("error: gradlew {s} exited with code {d}\n", .{ task, code });
            return error.GradleFailed;
        },
        else => return error.GradleFailed,
    }
    if (args.len == 3) return;

    const apk_dir, const out = .{ args[3], args[4] };
    var dir = try cwd.openDir(io, apk_dir, .{ .iterate = true });
    defer dir.close(io);
    var apk: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".apk")) continue;
        if (apk != null) {
            std.debug.print("error: more than one APK in {s}\n", .{apk_dir});
            return error.AmbiguousApk;
        }
        apk = try arena.dupe(u8, e.name);
    }
    const name = apk orelse {
        std.debug.print("error: gradlew {s} left no APK in {s}\n", .{ task, apk_dir });
        return error.NoApk;
    };
    try dir.copyFile(name, cwd, out, io, .{});
}
