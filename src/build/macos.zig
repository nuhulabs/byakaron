//! Build-time helper for the macOS app, run by the `*-macos` build steps.
//!
//!   macos stop
//!   macos launch <app>                    stop, then open <app>
//!   macos install <app>                   install into /Applications and launch
//!   macos uninstall [--remove-user-data]
//!   macos dmg <app> <out-dir>             drag-to-Applications Byakaron.dmg
//!
//! Replaces apps/macos/scripts/{install,uninstall,create_dmg}.sh.

const std = @import("std");
const Io = std.Io;

const app_name = "Byakaron";
const applications = "/Applications";
const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const home = init.environ_map.get("HOME") orelse return error.NoHome;

    const command = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, command, "stop") and args.len == 2) {
        try stop(io);
    } else if (std.mem.eql(u8, command, "launch") and args.len == 3) {
        try stop(io);
        try run(io, &.{ "open", args[2] });
    } else if (std.mem.eql(u8, command, "install") and args.len == 3) {
        try install(arena, io, home, args[2]);
    } else if (std.mem.eql(u8, command, "uninstall") and args.len <= 3) {
        const remove_data = args.len == 3 and std.mem.eql(u8, args[2], "--remove-user-data");
        try uninstall(arena, io, home, remove_data);
    } else if (std.mem.eql(u8, command, "dmg") and args.len == 4) {
        try dmg(arena, io, args[2], args[3]);
    } else {
        std.debug.print("usage: {s} stop | launch <app> | install <app> | uninstall [--remove-user-data] | dmg <app> <out-dir>\n", .{args[0]});
        return error.InvalidArguments;
    }
}

/// Quit the app and its input method (and the names they shipped under before),
/// so a new copy can replace them and `open` starts the new binary.
fn stop(io: Io) !void {
    var any = false;
    for ([_][]const u8{ app_name, "Byakaron Keyboard", "ByakaronIME", "AvroBangla" }) |name| {
        if (runQuiet(io, &.{ "killall", name })) any = true;
    }
    if (any) try io.sleep(.fromSeconds(1), .awake);
}

fn install(arena: std.mem.Allocator, io: Io, home: []const u8, app: []const u8) !void {
    try stop(io);

    const cwd = Io.Dir.cwd();
    const installed = applications ++ "/" ++ app_name ++ ".app";
    // Old installs, including legacy names and the old Input Methods copy.
    for ([_][]const u8{ installed, applications ++ "/AvroBangla.app" }) |p| cwd.deleteTree(io, p) catch {};
    for ([_][]const u8{ app_name ++ ".app", "ByakaronIME.app", "Byakaron Keyboard.app" }) |name| {
        cwd.deleteTree(io, try std.fs.path.join(arena, &.{ home, "Library/Input Methods", name })) catch {};
    }

    // On first launch the (non-sandboxed) app copies its embedded keyboard into
    // ~/Library/Input Methods and registers it (KeyboardInstaller.ensureInstalled).
    try run(io, &.{ "ditto", app, installed });
    // Ad-hoc signed: clear quarantine so Gatekeeper does not block it.
    _ = runQuiet(io, &.{ "xattr", "-cr", installed });

    // macOS resolves a bundle id to one path; leftover copies (build outputs,
    // DerivedData, the Trash) can make the input source resolve to the wrong one.
    _ = runQuiet(io, &.{ lsregister, "-f", installed });
    for (try registeredCopies(arena, io)) |p| {
        if (std.mem.eql(u8, p, installed) or std.mem.startsWith(u8, p, installed ++ "/")) continue;
        if (runQuiet(io, &.{ lsregister, "-u", p })) std.debug.print("unregistered stale copy: {s}\n", .{p});
    }

    try run(io, &.{ "open", installed });
    std.debug.print(
        \\Installed {s}. To enable the keyboard: System Settings → Keyboard →
        \\Input Sources → + → Byakaron (or Byakaron → Settings → Setup).
        \\
    , .{installed});
}

fn uninstall(arena: std.mem.Allocator, io: Io, home: []const u8, remove_data: bool) !void {
    try stop(io);

    for ([_][]const u8{ "Byakaron Keyboard.app", "ByakaronIME.app", app_name ++ ".app", "AvroBangla.app" }) |name| {
        try removeIfPresent(io, try std.fs.path.join(arena, &.{ home, "Library/Input Methods", name }));
    }
    for ([_][]const u8{ app_name ++ ".app", "AvroBangla.app" }) |name| {
        try removeIfPresent(io, try std.fs.path.join(arena, &.{ applications, name }));
    }
    // Drop every registration so a future install starts clean.
    for (try registeredCopies(arena, io)) |p| {
        if (runQuiet(io, &.{ lsregister, "-u", p })) std.debug.print("unregistered: {s}\n", .{p});
    }

    const user_data = [_][]const u8{
        "Library/Application Support/Byakaron", // learned word selections
        "Library/Preferences/dev.nuhu.labs.Byakaron.shared.plist", // shared settings
        "Library/Preferences/dev.nuhu.labs.inputmethod.Byakaron.plist", // IME settings
        "Library/Preferences/dev.nuhu.labs.Byakaron.plist", // app settings
        "Library/Saved Application State/dev.nuhu.labs.Byakaron.savedState", // window state
    };
    var kept = false;
    for (user_data) |rel| {
        const p = try std.fs.path.join(arena, &.{ home, rel });
        if (!exists(io, p)) continue;
        if (remove_data) {
            try removeIfPresent(io, p);
        } else {
            if (!kept) std.debug.print("kept user data (-Dmacos-remove-user-data=true removes it):\n", .{});
            std.debug.print("  {s}\n", .{p});
            kept = true;
        }
    }
    std.debug.print("Uninstalled. Log out and back in to finish removing the input source.\n", .{});
}

/// A drag-to-Applications disk image: the app next to a link to /Applications.
fn dmg(arena: std.mem.Allocator, io: Io, app: []const u8, out_dir: []const u8) !void {
    const plist = try std.fs.path.join(arena, &.{ app, "Contents/Info.plist" });
    const version_out = try std.process.run(arena, io, .{
        .argv = &.{ "plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist },
    });
    if (!version_out.term.success()) return error.NoVersion;
    const version = std.mem.trim(u8, version_out.stdout, " \n");

    const cwd = Io.Dir.cwd();
    const stage = try std.fs.path.join(arena, &.{ out_dir, "stage" });
    cwd.deleteTree(io, stage) catch {};
    try cwd.createDirPath(io, stage);
    try run(io, &.{ "ditto", app, try std.fs.path.join(arena, &.{ stage, app_name ++ ".app" }) });
    try cwd.symLink(io, applications, try std.fs.path.join(arena, &.{ stage, "Applications" }), .{});

    const volname = try std.fmt.allocPrint(arena, "{s} {s}", .{ app_name, version });
    const out = try std.fmt.allocPrint(arena, "{s}/{s}.dmg", .{ out_dir, app_name });
    try run(io, &.{ "hdiutil", "create", "-quiet", "-volname", volname, "-srcfolder", stage, "-ov", "-format", "UDZO", out });
    try cwd.deleteTree(io, stage);
}

/// Every Byakaron bundle LaunchServices knows about.
fn registeredCopies(arena: std.mem.Allocator, io: Io) ![]const []const u8 {
    const dump = std.process.run(arena, io, .{
        .argv = &.{ lsregister, "-dump" },
        .stdout_limit = .limited(512 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return &.{};
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, dump.stdout, '\n');
    while (lines.next()) |line| {
        const start = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const end = (std.mem.lastIndexOf(u8, line, ".app") orelse continue) + ".app".len;
        if (end <= start) continue;
        const p = line[start..end];
        if (std.mem.indexOf(u8, p, app_name) == null or std.mem.indexOfScalar(u8, p, '"') != null) continue;
        try seen.put(arena, p, {});
    }
    return seen.keys();
}

fn exists(io: Io, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn removeIfPresent(io: Io, p: []const u8) !void {
    if (!exists(io, p)) return;
    std.debug.print("removing {s}\n", .{p});
    try Io.Dir.cwd().deleteTree(io, p);
}

fn run(io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("error: {s} failed ({any})\n", .{ argv[0], term });
        return error.CommandFailed;
    }
}

/// Run `argv` with its output discarded; true when it succeeded.
fn runQuiet(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}
