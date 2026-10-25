// gradle <project> <task> [<apk-dir> <out.apk>]

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
    const cwd = Io.Dir.cwd();

    // Old APKs would sit next to the new one.
    if (args.len == 5) {
        if (cwd.openDir(io, args[3], .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(io);
            for (try apks(arena, io, dir)) |name| try dir.deleteFile(io, name);
        } else |err| if (err != error.FileNotFound) return err;
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{ if (builtin.os.tag == .windows) "gradlew.bat" else "./gradlew", "--quiet", "--console=plain", task },
        .cwd = .{ .path = project },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.debug.print("error: gradlew {s} failed\n", .{task});
        return error.GradleFailed;
    }
    if (args.len == 3) return;

    var dir = try cwd.openDir(io, args[3], .{ .iterate = true });
    defer dir.close(io);
    const found = try apks(arena, io, dir);
    if (found.len != 1) {
        std.debug.print("error: expected one APK in {s}, found {d}\n", .{ args[3], found.len });
        return error.NoApk;
    }
    try dir.copyFile(found[0], cwd, args[4], io, .{});
}

fn apks(arena: std.mem.Allocator, io: Io, dir: Io.Dir) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".apk")) try out.append(arena, try arena.dupe(u8, e.name));
    }
    return out.items;
}
