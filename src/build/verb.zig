//! `zig build <verb> -- <target>…`, run by the verb steps in build.zig.
//!
//!   verb <zig> <verb> <multi:0|1> <usage-file> <targets,…> [forwarded flags…] -- [args…]
//!
//! The build is configured before the args after `--` are known, so a verb
//! step cannot pick its targets itself. This picks them from the args and
//! runs `zig build <verb> -Dselect=<targets>` with the flags this build was
//! configured with (forwarded by build.zig), so that build has only the
//! targets' steps; for a single-target verb the args after the target go
//! after its `--`, where its run steps take them. `-D` options and
//! `--release` among the args are taken as the build's own flags.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 6) {
        std.debug.print("usage: {s} <zig> <verb> <multi> <usage-file> <targets> [flags…] -- [args…]\n", .{argv[0]});
        return 2;
    }
    const zig, const verb, const multi, const targets_csv =
        .{ argv[1], argv[2], std.mem.eql(u8, argv[3], "1"), argv[5] };
    const usage = try std.Io.Dir.cwd().readFileAlloc(io, argv[4], arena, .limited(64 * 1024));

    const dash = for (argv[6..], 6..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else argv.len;
    // `-D` options and `--release` after `--` (`zig build gen -- db -Dwiki-date=…`)
    // are this build's flags too.
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.appendSlice(arena, argv[6..dash]);
    var args: std.ArrayList([]const u8) = .empty;
    if (dash < argv.len) for (argv[dash + 1 ..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "--release")) {
            try flags.append(arena, arg);
        } else try args.append(arena, arg);
    };

    if (args.items.len == 0) {
        std.debug.print("{s}", .{usage});
        return 1;
    }

    var selected: std.ArrayList(u8) = .empty;
    var rest: []const []const u8 = &.{};
    for (args.items, 0..) |arg, i| {
        if (!multi and i > 0) {
            rest = args.items[i..];
            break;
        }
        if (!isTarget(targets_csv, arg)) {
            std.debug.print("`{s}` is not a `zig build {s}` target\n{s}", .{ arg, verb, usage });
            return 1;
        }
        if (selected.items.len > 0) try selected.append(arena, ',');
        try selected.appendSlice(arena, arg);
    }

    var child_argv: std.ArrayList([]const u8) = .empty;
    try child_argv.appendSlice(arena, &.{ zig, "build", verb, try std.fmt.allocPrint(arena, "-Dselect={s}", .{selected.items}) });
    try child_argv.appendSlice(arena, flags.items);
    if (rest.len > 0) {
        try child_argv.append(arena, "--");
        try child_argv.appendSlice(arena, rest);
    }

    var child = std.process.spawn(io, .{ .argv = child_argv.items, .stdin = .inherit }) catch |err| {
        std.debug.print("cannot run {s}: {t}\n", .{ zig, err });
        return 1;
    };
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}

fn isTarget(csv: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |t| if (std.mem.eql(u8, t, name)) return true;
    return false;
}

test isTarget {
    try std.testing.expect(isTarget("macos,linux", "linux"));
    try std.testing.expect(!isTarget("macos,linux", "lin"));
}
