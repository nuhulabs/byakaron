//! Build-time driver for `xcodebuild`, run by `zig build macos`.
//!
//!   xcode <project> <scheme> <configuration> <derived-data> <out-dir> <log-dir>
//!
//! Runs the Xcode build with ad-hoc signing, turns its task lines into a
//! `std.Progress` tree (one node per target, with the current task under it),
//! and prints only diagnostics: errors on failure, a warning count on success.
//! The full output is kept in `<log-dir>/build.log` (stdout) and `stderr.log`.
//! On success the product is copied to `<out-dir>/<scheme>.app`, which the
//! build installs into zig-out/.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) {
        std.debug.print("usage: {s} <project> <scheme> <configuration> <derived-data> <out-dir> <log-dir>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const project, const scheme, const configuration, const derived_data, const out_dir, const log_dir =
        .{ args[1], args[2], args[3], args[4], args[5], args[6] };

    const progress = std.Progress.start(io, .{ .root_name = "xcodebuild" });
    defer progress.end();

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, log_dir);
    const log_path = try std.fs.path.join(arena, &.{ log_dir, "build.log" });
    var log_file = try cwd.createFile(io, log_path, .{});
    defer log_file.close(io);
    var stderr_file = try cwd.createFile(io, try std.fs.path.join(arena, &.{ log_dir, "stderr.log" }), .{});
    defer stderr_file.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "xcodebuild",
            "-project",
            project,
            "-scheme",
            scheme,
            "-configuration",
            configuration,
            "-derivedDataPath",
            derived_data,
            // Ad-hoc signed so the result installs and runs without a developer
            // certificate. Each target's entitlements come from its
            // CODE_SIGN_ENTITLEMENTS setting.
            "CODE_SIGN_STYLE=Manual",
            "CODE_SIGN_IDENTITY=-",
            "DEVELOPMENT_TEAM=",
            "PROVISIONING_PROFILE_SPECIFIER=",
            "CODE_SIGNING_REQUIRED=YES",
            "CODE_SIGNING_ALLOWED=YES",
            "build",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = stderr_file },
    });

    var log_buf: [64 * 1024]u8 = undefined;
    var log = log_file.writer(io, &log_buf);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const r = &reader.interface;

    var targets: std.StringArrayHashMapUnmanaged(std.Progress.Node) = .empty;
    var task: std.Progress.Node = .none;
    var diagnostics: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var errors: usize = 0;
    var warnings: usize = 0;
    var succeeded = false;

    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            // A line longer than the buffer (environment dumps): skip it.
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => |e| return e,
        } orelse break;
        try log.interface.writeAll(line);
        try log.interface.writeByte('\n');

        if (diagnosticKind(line)) |kind| {
            const gop = try seen.getOrPut(arena, line);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try arena.dupe(u8, line);
            try diagnostics.append(arena, gop.key_ptr.*);
            switch (kind) {
                .err => errors += 1,
                .warning => warnings += 1,
            }
        } else if (std.mem.eql(u8, line, "** BUILD SUCCEEDED **")) {
            succeeded = true;
        } else if (parseTask(line)) |t| {
            const gop = try targets.getOrPut(arena, t.target);
            if (!gop.found_existing) {
                gop.key_ptr.* = try arena.dupe(u8, t.target);
                gop.value_ptr.* = progress.start(gop.key_ptr.*, 0);
            }
            task.end();
            gop.value_ptr.completeOne();
            var name_buf: [128]u8 = undefined;
            var name: std.ArrayList(u8) = .initBuffer(&name_buf);
            for ([_][]const u8{ t.action, " ", t.subject }) |part| {
                var i: usize = 0;
                while (i < part.len and name.unusedCapacitySlice().len > 0) : (i += 1) {
                    if (part[i] == '\\' and i + 1 < part.len) i += 1; // Xcode escapes spaces
                    name.appendAssumeCapacity(part[i]);
                }
            }
            task = gop.value_ptr.start(name.items, 0);
        }
    }
    try log.interface.flush();
    task.end();
    for (targets.values()) |node| node.end();

    const term = try child.wait(io);
    if (!term.success() or !succeeded) {
        for (diagnostics.items) |d| if (diagnosticKind(d) == .err) std.debug.print("{s}\n", .{d});
        if (errors == 0) std.debug.print("xcodebuild failed ({any}) without reporting an error\n", .{term});
        std.debug.print("full log: {s}\n", .{log_path});
        return error.XcodeBuildFailed;
    }
    if (warnings > 0) std.debug.print("xcodebuild: {d} warning(s); full log: {s}\n", .{ warnings, log_path });

    const copy = progress.start("copy Byakaron.app", 0);
    defer copy.end();
    const product = try std.fmt.allocPrint(arena, "{s}/Build/Products/{s}/{s}.app", .{ derived_data, configuration, scheme });
    const app_out = try std.fmt.allocPrint(arena, "{s}/{s}.app", .{ out_dir, scheme });
    cwd.deleteTree(io, app_out) catch {};
    // ditto keeps the bundle's symlinks, permissions and code signatures.
    var ditto = try std.process.spawn(io, .{ .argv = &.{ "ditto", product, app_out }, .stdin = .ignore });
    if (!(try ditto.wait(io)).success()) return error.CopyFailed;
}

const Kind = enum { err, warning };

/// `path:line:col: error: …`, or a top-level `error: …` from xcodebuild.
fn diagnosticKind(line: []const u8) ?Kind {
    if (line.len == 0 or line[0] == ' ' or line[0] == '|') return null; // source excerpts
    if (std.mem.startsWith(u8, line, "error: ") or std.mem.indexOf(u8, line, ": error: ") != null) return .err;
    if (std.mem.startsWith(u8, line, "warning: ") or std.mem.indexOf(u8, line, ": warning: ") != null) return .warning;
    return null;
}

const Task = struct { action: []const u8, subject: []const u8, target: []const u8 };

/// `SwiftCompile normal arm64 Compiling\ Foo.swift /…/Foo.swift (in target 'T' from project 'P')`
/// → action `SwiftCompile`, subject `Foo.swift`, target `T`.
fn parseTask(line: []const u8) ?Task {
    const marker = " (in target '";
    const at = std.mem.indexOf(u8, line, marker) orelse return null;
    const rest = line[at + marker.len ..];
    const target = rest[0 .. std.mem.indexOfScalar(u8, rest, '\'') orelse return null];
    const head = line[0..at];
    const action_end = std.mem.indexOfScalar(u8, head, ' ') orelse head.len;
    // The last path component of the last argument, up to an unescaped space.
    const slash = std.mem.lastIndexOfScalar(u8, head, '/') orelse action_end;
    var subject = head[@min(slash + 1, head.len)..];
    var i: usize = 0;
    while (i < subject.len) : (i += 1) {
        if (subject[i] == ' ' and (i == 0 or subject[i - 1] != '\\')) {
            subject = subject[0..i];
            break;
        }
    }
    return .{ .action = head[0..action_end], .subject = subject, .target = target };
}
