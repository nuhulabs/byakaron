//! End-to-end test of the iOS keyboard's switch from the system keyboard to
//! Byakaron (KeyboardUITests/KeyboardSwitchTests) on a matrix of simulators,
//! run by `zig build e2e -- ios [args]`.
//!
//!   ios_e2e <keyboard-dir> [--devices GLOBS] [--os SPEC] [--appearance light|dark] [-j N]
//!           [--all-phones] [--keep-booted] [--list [--json]] [--products DIR]
//!   ios_e2e <keyboard-dir> analyze <folder> [--tolerance PX] [--flicker-threshold F]
//!
//! For each iPhone and iOS version picked it makes (or reuses) a simulator
//! named "Byakaron E2E <iPhone> <iOS>", gives it English, Byakaron and Emoji
//! as its keyboards, records a video while the test switches from English to
//! Byakaron, and checks that the two keyboards line up and the switch does
//! not flicker:
//!
//! - alignment: system.png and byakaron.png, the system's English keyboard
//!   and Byakaron's after the switch. Each key's drawn rectangle (found from
//!   the pixels, so labels do not matter) and the keyboard's top edge must be
//!   where the system's are, to within --tolerance pixels.
//! - flicker: switch.mp4, a video of the switch. Every frame from the tap to
//!   the end must be the system's keyboard, Byakaron's, or a blend of the two
//!   (a cross-fade); any other frame (blank, a different height, keys moving,
//!   something drawn and then redrawn) is a flicker. Such frames are saved as
//!   flicker-<n>.png.
//!
//! Options:
//!   --devices GLOBS    comma-separated globs (`*`, `?`) on the whole iPhone
//!                      name (default "iPhone 1*,iPhone Air*": iPhone 11 to 18
//!                      and Air; one exactly: --devices "iPhone 17e")
//!   --os SPEC          iOS versions, comma separated: "X+" or "X" for the
//!                      latest release of each major version from X (default
//!                      27+, the oldest the keyboard runs on), "27.0" for that
//!                      release
//!   -j N               simulators at once (more than 2 overloads a laptop)
//!   --all-phones       every iPhone, not only the newest of each screen size
//!   --keep-booted      leave the simulators running
//!   --list [--json]    print the matrix and stop (--json: [{"device","os"}]
//!                      for CI's job matrix; "device" works as --devices)
//!   --products DIR     a Build/Products dir from an earlier build-for-testing
//!                      instead of building (CI: build once, run per device)
//!
//! Results go to <keyboard-dir>/DerivedData/E2E/Results/<time>/<simulator>/
//! (screenshots, video, frames that flicker, report.json) with a
//! summary.json for the run; exits 1 if any simulator failed. `analyze`
//! checks one such folder again (writes its report.json, exits 1 if a check
//! fails). Needs Xcode and CocoaPods' workspace (pod install) and the engine
//! (zig build ios-libs); video frames are read with Support/e2e/frames.swift.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Value = json.Value;
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

const prefix = "Byakaron E2E";
const test_id = "KeyboardUITests/KeyboardSwitchTests";
const default_devices = "iPhone 1*,iPhone Air*";

/// Ad hoc signing keeps the App Group entitlement the app and keyboard need
/// (CODE_SIGNING_ALLOWED=NO drops it and the app stops at launch).
const signing = [_][]const u8{ "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=" };

const Tool = struct {
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    /// apps/ios/keyboard, absolute.
    kb: []const u8,
    log_mutex: Io.Mutex = .init,

    fn path(t: *Tool, parts: []const []const u8) []const u8 {
        return std.fs.path.join(t.arena, parts) catch oom();
    }

    fn fmt(t: *Tool, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(t.arena, f, args) catch oom();
    }

    /// One line to stdout, whole even with simulators running at once.
    fn log(t: *Tool, comptime f: []const u8, args: anytype) void {
        t.log_mutex.lockUncancelable(t.io);
        defer t.log_mutex.unlock(t.io);
        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writerStreaming(t.io, &buf);
        w.interface.print(f ++ "\n", args) catch {};
        w.interface.flush() catch {};
    }
};

fn oom() noreturn {
    std.process.fatal("out of memory", .{});
}

/// What went wrong, for the `error.Failed` that comes with it.
const Err = struct {
    msg: []const u8 = "",

    fn fail(e: *Err, t: *Tool, comptime f: []const u8, args: anytype) error{Failed} {
        e.msg = t.fmt(f, args);
        return error.Failed;
    }
};

const Options = struct {
    devices: []const u8 = default_devices,
    os: []const u8 = "27+",
    appearance: []const u8 = "light",
    jobs: usize = 1,
    all_phones: bool = false,
    keep_booted: bool = false,
    list: bool = false,
    json: bool = false,
    products: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch oom();
    if (args.len < 2) {
        std.debug.print("usage: {s} <keyboard-dir> [options] | <keyboard-dir> analyze <folder>\n", .{args[0]});
        return 2;
    }
    const kb = Io.Dir.cwd().realPathFileAlloc(init.io, args[1], arena) catch |err| {
        std.debug.print("{s}: {t}\n", .{ args[1], err });
        return 2;
    };
    var t: Tool = .{ .arena = arena, .io = init.io, .env = init.environ_map, .kb = kb };
    const rest = args[2..];
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "analyze")) return analyzeMain(&t, rest[1..]);
    return runMain(&t, rest) catch |err| {
        std.debug.print("ios_e2e: {t}\n", .{err});
        return 1;
    };
}

/// `--name value` or `--name=value`.
const ArgIter = struct {
    args: []const []const u8,
    i: usize = 0,

    fn value(a: *ArgIter, arg: []const u8, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, arg, name)) {
            if (a.i >= a.args.len) usage("{s} needs a value", .{name});
            a.i += 1;
            return a.args[a.i - 1];
        }
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') return arg[name.len + 1 ..];
        return null;
    }
};

fn usage(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("ios_e2e: " ++ f ++ "\n", args);
    std.process.exit(2);
}

fn parseOptions(args: []const []const u8) Options {
    var o: Options = .{};
    var it: ArgIter = .{ .args = args };
    while (it.i < args.len) {
        const arg = args[it.i];
        it.i += 1;
        if (it.value(arg, "--devices")) |v| {
            o.devices = v;
        } else if (it.value(arg, "--os")) |v| {
            o.os = v;
        } else if (it.value(arg, "--appearance")) |v| {
            if (!std.mem.eql(u8, v, "light") and !std.mem.eql(u8, v, "dark")) usage("--appearance is light or dark", .{});
            o.appearance = v;
        } else if (it.value(arg, "--jobs") orelse it.value(arg, "-j") orelse
            (if (std.mem.startsWith(u8, arg, "-j") and arg.len > 2) arg[2..] else null)) |v|
        {
            o.jobs = std.fmt.parseInt(usize, v, 10) catch usage("-j needs a number", .{});
        } else if (it.value(arg, "--products")) |v| {
            o.products = v;
        } else if (std.mem.eql(u8, arg, "--all-phones")) {
            o.all_phones = true;
        } else if (std.mem.eql(u8, arg, "--keep-booted")) {
            o.keep_booted = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            o.list = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            o.json = true;
        } else usage("unknown argument {s} (see the comment at the top of src/build/ios_e2e.zig)", .{arg});
    }
    return o;
}

// MARK: Processes

fn timeoutIn(io: Io, seconds: i64) Io.Timeout {
    return .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(seconds), .clock = .awake }) };
}

const Opts = struct { check: bool = true, timeout: i64 = 120 };

/// `xcrun simctl args…`, never waiting longer than `timeout` seconds (a
/// simulator runtime that cannot start leaves `bootstatus` waiting for ever).
/// Its stdout.
fn simctl(t: *Tool, e: *Err, args: []const []const u8, o: Opts) error{Failed}![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(t.arena, &.{ "xcrun", "simctl" }) catch oom();
    argv.appendSlice(t.arena, args) catch oom();
    const r = std.process.run(t.arena, t.io, .{
        .argv = argv.items,
        .environ_map = t.env,
        .timeout = timeoutIn(t.io, o.timeout),
    }) catch |err| {
        if (err == error.Timeout) {
            const what = if (args.len >= 2) t.fmt("{s} {s}", .{ args[0], args[1] }) else args[0];
            return e.fail(t, "simctl {s} did not finish in {d}s", .{ what, o.timeout });
        }
        return e.fail(t, "simctl {s} failed: {t}", .{ args[0], err });
    };
    if (o.check and !r.term.success()) {
        var detail: []const u8 = "";
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, r.stderr, " \t\r\n"), '\n');
        while (lines.next()) |l| detail = l;
        if (detail.len == 0) detail = switch (r.term) {
            .exited => |c| t.fmt("{d}", .{c}),
            else => t.fmt("{any}", .{r.term}),
        };
        return e.fail(t, "simctl {s} failed: {s}", .{ args[0], detail });
    }
    return r.stdout;
}

/// stdout of `argv`, or null when it failed.
fn capture(t: *Tool, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(t.arena, t.io, .{ .argv = argv, .environ_map = t.env }) catch return null;
    if (!r.term.success()) return null;
    return r.stdout;
}

fn plistJson(t: *Tool, file: []const u8) ?Value {
    const out = capture(t, &.{ "plutil", "-convert", "json", "-o", "-", file }) orelse return null;
    return json.parseFromSliceLeaky(Value, t.arena, out, .{}) catch null;
}

fn watchdog(io: Io, pid: Child.Id, seconds: i64, fired: *std.atomic.Value(bool)) void {
    io.sleep(.fromSeconds(seconds), .awake) catch return; // canceled: it ended in time
    fired.store(true, .release);
    std.posix.kill(pid, .KILL) catch {};
}

/// `child.wait`, killing it after `seconds`: null when it had to be killed.
fn waitTimeout(t: *Tool, child: *Child, seconds: i64) !?Child.Term {
    var fired: std.atomic.Value(bool) = .init(false);
    var dog = t.io.concurrent(watchdog, .{ t.io, child.id.?, seconds, &fired }) catch null;
    const term = child.wait(t.io);
    if (dog) |*d| d.cancel(t.io);
    const result = try term;
    return if (fired.load(.acquire)) null else result;
}

fn exists(t: *Tool, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(t.io, p, .{}) catch return false;
    return true;
}

fn nowSeconds(io: Io) f64 {
    return @as(f64, @floatFromInt(Io.Clock.real.now(io).toNanoseconds())) / 1e9;
}

/// Prints each step of one simulator's run with the time it took.
const Steps = struct {
    t: *Tool,
    label: []const u8,
    start: i96,
    last: i96,

    fn init(t: *Tool, label: []const u8) Steps {
        const now = Io.Clock.awake.now(t.io).toNanoseconds();
        return .{ .t = t, .label = label, .start = now, .last = now };
    }

    fn step(s: *Steps, comptime f: []const u8, args: anytype) void {
        const now = Io.Clock.awake.now(s.t.io).toNanoseconds();
        const since_last = @as(f64, @floatFromInt(now - s.last)) / 1e9;
        const since_start = @as(f64, @floatFromInt(now - s.start)) / 1e9;
        s.t.log("[{s}] " ++ f ++ " (+{d:.0}s, {d:.0}s in)", .{s.label} ++ args ++ .{ since_last, since_start });
        s.last = now;
    }
};

// MARK: JSON

fn get(v: ?Value, key: []const u8) ?Value {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn str(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn num(v: ?Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn items(v: ?Value) []Value {
    const val = v orelse return &.{};
    return switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
}

fn boolOr(v: ?Value, default: bool) bool {
    const val = v orelse return default;
    return switch (val) {
        .bool => |b| b,
        else => default,
    };
}

fn jstr(s: []const u8) Value {
    return .{ .string = s };
}

fn jint(i: i64) Value {
    return .{ .integer = i };
}

/// `round(x, places)` as Python's json writes it: no trailing zeros, but
/// always a decimal point.
fn jround(a: Allocator, x: f64, comptime places: usize) Value {
    var s = std.fmt.allocPrint(a, "{d:." ++ std.fmt.comptimePrint("{d}", .{places}) ++ "}", .{x}) catch oom();
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = @constCast(std.mem.trimEnd(u8, s, "0"));
        if (s[s.len - 1] == '.') s = std.fmt.allocPrint(a, "{s}0", .{s}) catch oom();
    }
    return .{ .number_string = s };
}

fn object() json.ObjectMap {
    return .empty;
}

fn put(a: Allocator, o: *json.ObjectMap, key: []const u8, v: Value) void {
    o.put(a, key, v) catch oom();
}

fn jsonText(a: Allocator, v: Value, indent: bool) []const u8 {
    return json.Stringify.valueAlloc(a, v, .{ .whitespace = if (indent) .indent_2 else .minified }) catch oom();
}

fn readJson(t: *Tool, file: []const u8) !Value {
    const text = try Io.Dir.cwd().readFileAlloc(t.io, file, t.arena, .limited(256 * 1024 * 1024));
    return json.parseFromSliceLeaky(Value, t.arena, text, .{}) catch |err| {
        std.debug.print("{s}: {t}\n", .{ file, err });
        return err;
    };
}

// MARK: Matrix

/// Up to three numbers of a version ("27.0.1", "27+"), compared like
/// Python tuples: a shorter one that is a prefix of a longer one is less.
const Version = struct {
    n: usize = 0,
    v: [3]u64 = .{ 0, 0, 0 },

    fn parse(text: []const u8) Version {
        var r: Version = .{};
        var i: usize = 0;
        while (i < text.len and r.n < 3) {
            if (!std.ascii.isDigit(text[i])) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            r.v[r.n] = std.fmt.parseInt(u64, text[i..j], 10) catch std.math.maxInt(u64);
            r.n += 1;
            i = j;
        }
        return r;
    }

    fn order(a: Version, b: Version) std.math.Order {
        for (0..@min(a.n, b.n)) |i| {
            if (a.v[i] != b.v[i]) return std.math.order(a.v[i], b.v[i]);
        }
        return std.math.order(a.n, b.n);
    }

    fn major(a: Version) ?u64 {
        return if (a.n > 0) a.v[0] else null;
    }
};

const Kind = struct { name: []const u8, identifier: []const u8, bundle_path: []const u8 };

const Runtime = struct {
    version: []const u8,
    identifier: []const u8,
    kinds: []const Kind,
};

const Pair = struct { kind: Kind, runtime: *const Runtime };

/// `pattern` matches the whole of `name`; `*` any run, `?` any one byte.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Any of the comma-separated globs in `globs` matches `name`.
fn globsMatch(globs: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, globs, ',');
    while (it.next()) |g| {
        const glob = std.mem.trim(u8, g, " \t");
        if (glob.len > 0 and globMatch(glob, name)) return true;
    }
    return false;
}

/// The iPhones matching `o.devices` on each iOS picked: the latest release
/// of each major version ("27+": the latest 27.x, and so on), unless
/// `o.os` names a release itself ("27.0"); one iPhone per screen size unless
/// `o.all_phones`.
fn matrix(t: *Tool, o: Options) ![]Pair {
    var e: Err = .{};
    const listing = simctl(t, &e, &.{ "list", "-j", "runtimes" }, .{}) catch {
        std.debug.print("{s}\n", .{e.msg});
        return error.Failed;
    };
    const root = try json.parseFromSliceLeaky(Value, t.arena, listing, .{});

    var wanted: std.ArrayList([]const u8) = .empty;
    var exact: std.ArrayList([]const u8) = .empty;
    if (o.os.len > 0) {
        var it = std.mem.splitScalar(u8, o.os, ',');
        while (it.next()) |v| {
            const spec = std.mem.trim(u8, v, " \t");
            try wanted.append(t.arena, spec);
            if (std.mem.indexOfScalar(u8, spec, '.') != null and !std.mem.endsWith(u8, spec, "+")) try exact.append(t.arena, spec);
        }
    }

    var empty: std.ArrayList([]const u8) = .empty;
    var named: std.ArrayList(*Runtime) = .empty;
    // Major version → the latest runtime of it, in the order majors appear.
    var latest: std.AutoArrayHashMapUnmanaged(u64, *Runtime) = .empty;
    for (items(get(root, "runtimes"))) |rt| {
        if (!std.mem.eql(u8, str(get(rt, "platform")) orelse "iOS", "iOS")) continue;
        if (!boolOr(get(rt, "isAvailable"), false)) {
            std.debug.print("skipping {s}: unavailable ({s})\n", .{ str(get(rt, "name")) orelse "?", str(get(rt, "availabilityError")) orelse "no reason given" });
            continue;
        }
        const version = str(get(rt, "version")) orelse continue;
        const runtime = try t.arena.create(Runtime);
        runtime.* = .{ .version = version, .identifier = str(get(rt, "identifier")) orelse continue, .kinds = try kindsOf(t, rt, o.devices) };
        // A runtime with none of the iPhones (CI images carry partial ones)
        // must not stand in for its major version: skip it, and say so only
        // if nothing is left.
        if (runtime.kinds.len == 0) {
            try empty.append(t.arena, t.fmt("iOS {s}: no iPhone matches --devices \"{s}\" ({d} device types)", .{ version, o.devices, items(get(rt, "supportedDeviceTypes")).len }));
            continue;
        }

        const is_named = for (exact.items) |v| {
            if (std.mem.eql(u8, version, v) or (std.mem.startsWith(u8, version, v) and version.len > v.len and version[v.len] == '.')) break true;
        } else false;
        if (is_named) {
            try named.append(t.arena, runtime);
            continue;
        }
        const vt = Version.parse(version);
        if (wanted.items.len > 0) {
            const wanted_here = for (wanted.items) |v| {
                if (isExact(exact.items, v)) continue;
                const spec = Version.parse(v);
                const ok = if (std.mem.endsWith(u8, v, "+"))
                    vt.order(spec) != .lt
                else
                    (vt.major() orelse 0) == (spec.major() orelse 0) and (vt.n > 0) == (spec.n > 0);
                if (ok) break true;
            } else false;
            if (!wanted_here) continue;
        }
        // One release per major version, the latest, besides any named exactly.
        const major = vt.major() orelse 0;
        const gop = try latest.getOrPut(t.arena, major);
        if (!gop.found_existing or vt.order(Version.parse(gop.value_ptr.*.version)) == .gt) gop.value_ptr.* = runtime;
    }

    var chosen: std.ArrayList(*Runtime) = .empty;
    try chosen.appendSlice(t.arena, named.items);
    try chosen.appendSlice(t.arena, latest.values());

    var pairs: std.ArrayList(Pair) = .empty;
    for (chosen.items) |runtime| {
        const kinds = if (o.all_phones) runtime.kinds else try onePerScreen(t, runtime.kinds);
        for (kinds) |kind| try pairs.append(t.arena, .{ .kind = kind, .runtime = runtime });
    }
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            switch (Version.parse(a.runtime.version).order(Version.parse(b.runtime.version))) {
                .lt => return true,
                .gt => return false,
                .eq => return std.mem.order(u8, a.kind.name, b.kind.name) == .lt,
            }
        }
    }.lessThan);
    if (pairs.items.len == 0) for (empty.items) |line| std.debug.print("{s}\n", .{line});
    return pairs.items;
}

fn isExact(exact: []const []const u8, v: []const u8) bool {
    for (exact) |x| if (std.mem.eql(u8, x, v)) return true;
    return false;
}

/// The runtime's iPhone device types whose name `devices` matches.
fn kindsOf(t: *Tool, rt: Value, devices: []const u8) ![]const Kind {
    var kinds: std.ArrayList(Kind) = .empty;
    for (items(get(rt, "supportedDeviceTypes"))) |k| {
        if (!std.mem.eql(u8, str(get(k, "productFamily")) orelse "iPhone", "iPhone")) continue;
        const name = str(get(k, "name")) orelse continue;
        if (!globsMatch(devices, name)) continue;
        try kinds.append(t.arena, .{
            .name = name,
            .identifier = str(get(k, "identifier")) orelse continue,
            .bundle_path = str(get(k, "bundlePath")) orelse "",
        });
    }
    return kinds.items;
}

/// A device type's screen in pixels (width, height, scale), as a key; its
/// identifier when unknown (its own group).
fn screenOf(t: *Tool, kind: Kind) []const u8 {
    const caps = t.path(&.{ kind.bundle_path, "Contents", "Resources", "capabilities.plist" });
    const info = plistJson(t, caps) orelse return kind.identifier;
    const screen = get(get(info, "capabilities") orelse info, "ScreenDimensionsCapability");
    const w = num(get(screen, "main-screen-width")) orelse return kind.identifier;
    const h = num(get(screen, "main-screen-height")) orelse return kind.identifier;
    const s = num(get(screen, "main-screen-scale")) orelse return kind.identifier;
    return t.fmt("{d}x{d}@{d}", .{ w, h, s });
}

/// The newest iPhone of each screen size (the plain model of its generation
/// where there is one): phones of one size share the system keyboard's
/// layout (Keyboard/Models/PhoneLayouts keys it by width), so testing more
/// of them repeats the same test.
fn onePerScreen(t: *Tool, kinds: []const Kind) ![]const Kind {
    const Best = struct { generation: u64, len: usize, kind: Kind };
    var newest: std.StringArrayHashMapUnmanaged(Best) = .empty;
    for (kinds) |kind| {
        const screen = screenOf(t, kind);
        // The latest generation, and in it the plain model ("iPhone 17"
        // before "iPhone 17 Pro").
        const v = Version.parse(kind.name);
        const best: Best = .{ .generation = v.major() orelse 0, .len = std.unicode.utf8CountCodepoints(kind.name) catch kind.name.len, .kind = kind };
        const gop = try newest.getOrPut(t.arena, screen);
        if (!gop.found_existing or best.generation > gop.value_ptr.generation or
            (best.generation == gop.value_ptr.generation and best.len < gop.value_ptr.len)) gop.value_ptr.* = best;
    }
    var out: std.ArrayList(Kind) = .empty;
    for (newest.values()) |b| try out.append(t.arena, b.kind);
    return out.items;
}

fn simulatorFor(t: *Tool, e: *Err, kind: Kind, runtime: *const Runtime) error{Failed}![2][]const u8 {
    const name = t.fmt("{s} {s} {s}", .{ prefix, kind.name, runtime.version });
    const listing = try simctl(t, e, &.{ "list", "-j", "devices" }, .{});
    const root = json.parseFromSliceLeaky(Value, t.arena, listing, .{}) catch return e.fail(t, "simctl list devices: bad JSON", .{});
    for (items(get(get(root, "devices"), runtime.identifier))) |device| {
        if (std.mem.eql(u8, str(get(device, "name")) orelse "", name) and boolOr(get(device, "isAvailable"), true)) {
            if (str(get(device, "udid"))) |udid| return .{ name, udid };
        }
    }
    const udid = try simctl(t, e, &.{ "create", name, kind.identifier, runtime.identifier }, .{});
    return .{ name, std.mem.trim(u8, udid, " \t\r\n") };
}

// MARK: Build

const Products = struct { xctestrun: []const u8, app: []const u8 };

fn build(t: *Tool) !Products {
    t.log("Building HostingApp and KeyboardUITests for testing…", .{});
    const e2e = t.path(&.{ t.kb, "DerivedData", "E2E" });
    const derived = t.path(&.{ e2e, "Build" });
    try Io.Dir.cwd().createDirPath(t.io, derived);
    const log_path = t.path(&.{ e2e, "build.log" });
    var log_file = try Io.Dir.cwd().createFile(t.io, log_path, .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t.arena, &.{
        "xcodebuild",                                   "build-for-testing",
        "-workspace",                                   t.path(&.{ t.kb, "GiellaKeyboard.xcworkspace" }),
        "-scheme",                                      "KeyboardUITests",
        "-sdk",                                         "iphonesimulator",
        "-destination",                                 "generic/platform=iOS Simulator",
        "-derivedDataPath",                             derived,
    });
    try argv.appendSlice(t.arena, &signing);
    var child = try std.process.spawn(t.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        .environ_map = t.env,
    });
    const term = try child.wait(t.io);
    log_file.close(t.io);
    if (!term.success()) {
        const text = Io.Dir.cwd().readFileAlloc(t.io, log_path, t.arena, .limited(1024 * 1024 * 1024)) catch "";
        var errors: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (std.mem.indexOf(u8, l, "error:") == null) continue;
            const s = std.mem.trim(u8, l, " \t\r");
            if ((try seen.getOrPut(t.arena, s)).found_existing) continue;
            try errors.append(t.arena, s);
        }
        std.mem.sort([]const u8, errors.items, {}, lessString);
        std.debug.print("build failed:\n", .{});
        for (errors.items[0..@min(30, errors.items.len)]) |l| std.debug.print("{s}\n", .{l});
        std.debug.print("full log: {s}\n", .{log_path});
        return error.BuildFailed;
    }
    return findProducts(t, t.path(&.{ derived, "Build", "Products" }));
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The last KeyboardUITests_*.xctestrun and HostingApp.app in `products`.
fn findProducts(t: *Tool, products: []const u8) !Products {
    var runs: std.ArrayList([]const u8) = .empty;
    if (Io.Dir.cwd().openDir(t.io, products, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(t.io);
        var it = dir.iterate();
        while (try it.next(t.io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "KeyboardUITests_") and std.mem.endsWith(u8, entry.name, ".xctestrun"))
                try runs.append(t.arena, try t.arena.dupe(u8, entry.name));
        }
    } else |_| {}
    std.mem.sort([]const u8, runs.items, {}, lessString);
    const app = t.path(&.{ products, "Debug-iphonesimulator", "HostingApp.app" });
    if (runs.items.len == 0 or !exists(t, app)) {
        std.debug.print("no .xctestrun or HostingApp.app in {s}\n", .{products});
        return error.NoProducts;
    }
    return .{ .xctestrun = t.path(&.{ products, runs.items[runs.items.len - 1] }), .app = app };
}

fn keyboardBundleId(t: *Tool, app: []const u8) ![]const u8 {
    const plugins = t.path(&.{ app, "PlugIns" });
    if (Io.Dir.cwd().openDir(t.io, plugins, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(t.io);
        var it = dir.iterate();
        while (try it.next(t.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".appex")) continue;
            const info = plistJson(t, t.path(&.{ plugins, entry.name, "Info.plist" })) orelse continue;
            const point = str(get(get(info, "NSExtension"), "NSExtensionPointIdentifier")) orelse continue;
            if (std.mem.eql(u8, point, "com.apple.keyboard-service")) {
                if (str(get(info, "CFBundleIdentifier"))) |id| return id;
            }
        }
    } else |_| {}
    std.debug.print("no keyboard extension in {s}\n", .{app});
    return error.NoKeyboard;
}

// MARK: One simulator

fn boot(t: *Tool, e: *Err, udid: []const u8) !void {
    _ = try simctl(t, e, &.{ "boot", udid }, .{ .check = false, .timeout = 180 });
    _ = try simctl(t, e, &.{ "bootstatus", udid, "-b" }, .{ .timeout = 300 });
}

/// Boot with the app installed and English, Byakaron and Emoji as the
/// keyboards, in that order (one tap on the globe goes English → Byakaron).
fn prepare(t: *Tool, e: *Err, udid: []const u8, app: []const u8, keyboard_id: []const u8, appearance: []const u8, steps: *Steps) !void {
    try boot(t, e, udid);
    steps.step("booted", .{});
    _ = try simctl(t, e, &.{ "install", udid, app }, .{ .timeout = 300 }); // a fresh simulator is slow at first
    steps.step("installed the app", .{});
    const spawn = [_][]const u8{ "spawn", udid, "defaults", "write" };
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "-g", "AppleKeyboards", "-array", "en_US@sw=QWERTY;hw=Automatic", keyboard_id, "emoji@sw=Emoji" }), .{});
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "-g", "AppleKeyboardsExpanded", "-int", "1" }), .{});
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "-g", "AppleLanguages", "-array", "en-US" }), .{});
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "-g", "AppleLocale", "en_US" }), .{});
    // No "slide to type" introduction over the keyboard the first time.
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "com.apple.keyboard.preferences", "DidShowContinuousPathIntroduction", "-bool", "true" }), .{});
    _ = try simctl(t, e, &(spawn ++ [_][]const u8{ "com.apple.keyboard.preferences", "DidShowGestureKeyboardIntroduction", "-bool", "true" }), .{});
    // Reboot so the keyboard list is read afresh.
    _ = try simctl(t, e, &.{ "shutdown", udid }, .{ .check = false, .timeout = 120 });
    try boot(t, e, udid);
    steps.step("set the keyboards and rebooted", .{});
    _ = try simctl(t, e, &.{ "ui", udid, "appearance", appearance }, .{});
    _ = try simctl(t, e, &.{ "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3" }, .{ .check = false });
}

/// `simctl io recordVideo` for the length of the test; `started` is the host
/// clock (seconds since 1970) when the first frame was being recorded.
const Recorder = struct {
    child: Child,
    started: f64,

    fn start(t: *Tool, e: *Err, udid: []const u8, file: []const u8) !Recorder {
        // exec: the pid is xcrun's, which gets the SIGINT that stops it.
        var child = std.process.spawn(t.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec xcrun simctl io \"$0\" recordVideo --codec=h264 --force \"$1\" 2>&1", udid, file },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .environ_map = t.env,
        }) catch |err| return e.fail(t, "cannot run simctl io recordVideo: {t}", .{err});
        var buffer: Io.File.MultiReader.Buffer(1) = undefined;
        var mr: Io.File.MultiReader = undefined;
        mr.init(t.arena, t.io, buffer.toStreams(), &.{child.stdout.?});
        const deadline = timeoutIn(t.io, 20);
        const started: ?f64 = while (true) {
            mr.fill(64, deadline) catch break null;
            if (std.mem.indexOf(u8, mr.reader(0).buffered(), "Recording started") != null) break nowSeconds(t.io);
        };
        mr.deinit();
        if (started == null) {
            child.kill(t.io);
            return e.fail(t, "the simulator did not start recording", .{});
        }
        return .{ .child = child, .started = started.? };
    }

    fn stop(r: *Recorder, t: *Tool) void {
        std.posix.kill(r.child.id.?, .INT) catch {};
        _ = waitTimeout(t, &r.child, 30) catch {};
    }
};

/// `iPhone 17 Pro iOS 27.0` → `iPhone-17-Pro-iOS-27.0`.
fn folderName(a: Allocator, label: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    for (label) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.') {
            if (gap and out.items.len > 0) out.append(a, '-') catch oom();
            gap = false;
            out.append(a, c) catch oom();
        } else gap = true;
    }
    return out.items;
}

const Run = struct {
    t: *Tool,
    o: Options,
    products: Products,
    keyboard_id: []const u8,
    results: []const u8,
    self_exe: []const u8,
    pairs: []const Pair,
    entries: []Value,
    next: std.atomic.Value(usize) = .init(0),
};

fn worker(r: *Run) void {
    while (true) {
        const i = r.next.fetchAdd(1, .monotonic);
        if (i >= r.pairs.len) return;
        r.entries[i] = runOne(r, r.pairs[i]);
    }
}

fn runOne(r: *Run, pair: Pair) Value {
    const t = r.t;
    const a = t.arena;
    const label = t.fmt("{s} iOS {s}", .{ pair.kind.name, pair.runtime.version });
    const out = t.path(&.{ r.results, folderName(a, label) });
    var entry = object();
    put(a, &entry, "device", jstr(pair.kind.name));
    put(a, &entry, "os", jstr(pair.runtime.version));
    var steps: Steps = .init(t, label);
    var e: Err = .{};

    var udid: ?[]const u8 = null;
    var test_result: ?[]const u8 = null;
    var failures: std.ArrayList([]const u8) = .empty;
    var aligned: ?bool = null;
    var analysis: ?Value = null;
    body: {
        const sim = simulatorFor(t, &e, pair.kind, pair.runtime) catch {
            put(a, &entry, "dir", jstr(out));
            put(a, &entry, "error", jstr(e.msg));
            break :body;
        };
        udid = sim[1];
        Io.Dir.cwd().createDirPath(t.io, out) catch |err| {
            put(a, &entry, "error", jstr(t.fmt("{s}: {t}", .{ out, err })));
            break :body;
        };
        put(a, &entry, "simulator", jstr(sim[0]));
        put(a, &entry, "udid", jstr(sim[1]));
        put(a, &entry, "dir", jstr(out));
        oneSimulator(r, &e, &entry, out, sim[1], &steps, &test_result, &failures, &aligned, &analysis) catch {
            put(a, &entry, "error", jstr(if (e.msg.len > 0) e.msg else "failed"));
        };
    }
    if (!r.o.keep_booted) if (udid) |id| {
        var ignored: Err = .{};
        _ = simctl(t, &ignored, &.{ "shutdown", id }, .{ .check = false, .timeout = 60 }) catch {};
    };
    const ok = test_result != null and std.mem.eql(u8, test_result.?, "passed") and aligned == true;
    put(a, &entry, "ok", .{ .bool = ok });

    const summary: []const u8 = blk: {
        if (str(get(analysis, "summary"))) |s| if (s.len > 0) break :blk s;
        if (str(entry.get("error"))) |s| if (s.len > 0) break :blk s;
        if (failures.items.len > 0) {
            const joined = std.mem.join(a, ", ", failures.items) catch oom();
            break :blk joined[0..prefixLen(joined, 200)];
        }
        break :blk t.fmt("test {s}", .{test_result orelse "not run"});
    };
    t.log("[{s}] {s} {s}", .{ label, if (ok) "PASS" else "FAIL", summary });
    return .{ .object = entry };
}

/// Bytes in the first `n` code points of `s` (Python's s[:n]).
fn prefixLen(s: []const u8, n: usize) usize {
    var view = std.unicode.Utf8View.init(s) catch return @min(n, s.len);
    var it = view.iterator();
    var count: usize = 0;
    while (count < n) : (count += 1) _ = it.nextCodepointSlice() orelse break;
    return it.i;
}

fn oneSimulator(
    r: *Run,
    e: *Err,
    entry: *json.ObjectMap,
    out: []const u8,
    udid: []const u8,
    steps: *Steps,
    test_result: *?[]const u8,
    failures: *std.ArrayList([]const u8),
    aligned: *?bool,
    analysis: *?Value,
) !void {
    const t = r.t;
    const a = t.arena;
    steps.step("preparing {s}", .{udid});
    try prepare(t, e, udid, r.products.app, r.keyboard_id, r.o.appearance, steps);
    var recorder = try Recorder.start(t, e, udid, t.path(&.{ out, "switch.mp4" }));
    steps.step("recording; running the test (about a minute)", .{});

    var env = t.env.clone(a) catch oom();
    env.put("TEST_RUNNER_E2E_OUT", out) catch oom();
    const log_path = t.path(&.{ out, "xcodebuild.log" });
    var code: i32 = 1;
    {
        var log_file = Io.Dir.cwd().createFile(t.io, log_path, .{}) catch |err| {
            recorder.stop(t);
            return e.fail(t, "{s}: {t}", .{ log_path, err });
        };
        defer log_file.close(t.io);
        var child = std.process.spawn(t.io, .{
            .argv = &.{
                "xcodebuild",                                 "test-without-building",
                "-xctestrun",                                 r.products.xctestrun,
                "-destination",                               t.fmt("id={s}", .{udid}),
                t.fmt("-only-testing:{s}", .{test_id}),       "-resultBundlePath",
                t.path(&.{ out, "result.xcresult" }),
            },
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
            .environ_map = &env,
        }) catch |err| {
            recorder.stop(t);
            return e.fail(t, "cannot run xcodebuild: {t}", .{err});
        };
        const term = waitTimeout(t, &child, 600) catch |err| {
            recorder.stop(t);
            return e.fail(t, "xcodebuild: {t}", .{err});
        };
        code = if (term) |tm| switch (tm) {
            .exited => |c| c,
            else => 1,
        } else -1;
    }
    recorder.stop(t);
    var rec = object();
    put(a, &rec, "started", .{ .number_string = t.fmt("{d}", .{recorder.started}) });
    Io.Dir.cwd().writeFile(t.io, .{ .sub_path = t.path(&.{ out, "recording.json" }), .data = jsonText(a, .{ .object = rec }, false) }) catch {};

    test_result.* = if (code == 0) "passed" else if (code == -1) "timed out" else "failed";
    put(a, entry, "test", jstr(test_result.*.?));
    steps.step("test {s}", .{test_result.*.?});
    if (code != 0) {
        const text = Io.Dir.cwd().readFileAlloc(t.io, log_path, a, .limited(1024 * 1024 * 1024)) catch "";
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (failures.items.len == 10) break;
            if (std.mem.indexOf(u8, l, "error:") != null or std.mem.indexOf(u8, l, "Skipped") != null)
                failures.append(a, std.mem.trim(u8, l, " \t\r")) catch oom();
        }
        var list = json.Array.init(a);
        for (failures.items) |f| list.append(jstr(f)) catch oom();
        put(a, entry, "failures", .{ .array = list });
    }
    if (exists(t, t.path(&.{ out, "keys.json" }))) {
        steps.step("analysing screenshots and video", .{});
        const result = std.process.run(a, t.io, .{
            .argv = &.{ r.self_exe, t.kb, "analyze", out },
            .environ_map = t.env,
        }) catch |err| return e.fail(t, "cannot run the analysis: {t}", .{err});
        const log_text = std.mem.concat(a, u8, &.{ result.stdout, result.stderr }) catch oom();
        Io.Dir.cwd().writeFile(t.io, .{ .sub_path = t.path(&.{ out, "analyze.log" }), .data = log_text }) catch {};
        const report = t.path(&.{ out, "report.json" });
        if (exists(t, report)) {
            if (readJson(t, report)) |v| {
                analysis.* = v;
                put(a, entry, "analysis", v);
            } else |_| {}
        }
        aligned.* = result.term == .exited and result.term.exited == 0;
        put(a, entry, "aligned", .{ .bool = aligned.*.? });
    }
}

fn runMain(t: *Tool, args: []const []const u8) !u8 {
    const o = parseOptions(args);
    const pairs = try matrix(t, o);
    if (pairs.len == 0) {
        std.debug.print("no simulator matches: see `xcrun simctl list runtimes` and --devices / --os\n", .{});
        // CI's job matrix: an empty one (no runtime wanted on this runner
        // yet) skips the runs instead of failing the build.
        if (!(o.list and o.json)) return 1;
    }
    if (o.list) {
        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writerStreaming(t.io, &buf);
        if (o.json) {
            var list = json.Array.init(t.arena);
            for (pairs) |p| {
                var item = object();
                put(t.arena, &item, "device", jstr(p.kind.name));
                put(t.arena, &item, "os", jstr(p.runtime.version));
                try list.append(.{ .object = item });
            }
            try w.interface.print("{s}\n", .{jsonText(t.arena, .{ .array = list }, false)});
        } else {
            for (pairs) |p| try w.interface.print("{s:<24} iOS {s}\n", .{ p.kind.name, p.runtime.version });
        }
        try w.interface.flush();
        return 0;
    }

    const products = if (o.products) |dir| try findProducts(t, dir) else try build(t);
    const keyboard_id = try keyboardBundleId(t, products.app);

    const stamp = std.mem.trim(u8, capture(t, &.{ "date", "+%Y%m%d-%H%M%S" }) orelse return error.NoDate, " \r\n");
    const results = t.path(&.{ t.kb, "DerivedData", "E2E", "Results", stamp });
    try Io.Dir.cwd().createDirPath(t.io, results);
    t.log("{d} simulators, results in {s}", .{ pairs.len, results });

    var r: Run = .{
        .t = t,
        .o = o,
        .products = products,
        .keyboard_id = keyboard_id,
        .results = results,
        .self_exe = try std.process.executablePathAlloc(t.io, t.arena),
        .pairs = pairs,
        .entries = try t.arena.alloc(Value, pairs.len),
    };
    var group: Io.Group = .init;
    var workers: usize = 0;
    while (workers < @max(1, @min(o.jobs, pairs.len))) : (workers += 1) {
        group.concurrent(t.io, worker, .{&r}) catch break;
    }
    if (workers == 0) worker(&r); // no concurrency: one at a time
    try group.await(t.io);

    var list = json.Array.init(t.arena);
    try list.appendSlice(r.entries);
    const summary_path = t.path(&.{ results, "summary.json" });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = summary_path, .data = jsonText(t.arena, .{ .array = list }, true) });

    var failed: usize = 0;
    for (r.entries) |entry| {
        if (!boolOr(get(entry, "ok"), false)) failed += 1;
    }
    t.log("\n{d}/{d} passed; summary: {s}", .{ r.entries.len - failed, r.entries.len, summary_path });
    for (r.entries) |entry| {
        if (boolOr(get(entry, "ok"), false)) continue;
        t.log("  FAIL {s} iOS {s}: {s}", .{ str(get(entry, "device")) orelse "", str(get(entry, "os")) orelse "", str(get(entry, "dir")) orelse "" });
    }
    return if (failed > 0) 1 else 0;
}

// MARK: Images

/// 8-bit RGB pixels, row by row.
const Image = struct {
    w: usize,
    h: usize,
    rgb: []const u8,

    fn px(img: Image, x: usize, y: usize) [3]i32 {
        const i = (y * img.w + x) * 3;
        return .{ img.rgb[i], img.rgb[i + 1], img.rgb[i + 2] };
    }
};

const png_signature = "\x89PNG\r\n\x1a\n";

/// A non-interlaced 8-bit greyscale, grey+alpha, RGB or RGBA PNG, as RGB
/// (alpha dropped, as PIL's convert("RGB") does).
fn decodePng(a: Allocator, data: []const u8) !Image {
    if (!std.mem.startsWith(u8, data, png_signature)) return error.NotPng;
    var pos: usize = png_signature.len;
    var w: usize = 0;
    var h: usize = 0;
    var channels: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(a);
    var seen_header = false;
    while (pos + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 .. pos + 8];
        if (pos + 12 + len > data.len) return error.TruncatedPng;
        const body = data[pos + 8 .. pos + 8 + len];
        const crc = std.mem.readInt(u32, data[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(data[pos + 4 .. pos + 8 + len]) != crc) return error.PngChecksum;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (body.len != 13) return error.BadPngHeader;
            w = std.mem.readInt(u32, body[0..4], .big);
            h = std.mem.readInt(u32, body[4..8], .big);
            const depth = body[8];
            const color = body[9];
            if (depth != 8) return error.UnsupportedPngBitDepth;
            channels = switch (color) {
                0 => 1,
                2 => 3,
                4 => 2,
                6 => 4,
                else => return error.UnsupportedPngColorType, // palette
            };
            if (body[10] != 0 or body[11] != 0) return error.BadPngHeader;
            if (body[12] != 0) return error.UnsupportedPngInterlace;
            seen_header = true;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(a, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    if (!seen_header) return error.BadPngHeader;

    const stride = w * channels;
    var input: Io.Reader = .fixed(idat.items);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, window);
    const raw = inflate.reader.allocRemaining(a, .limited((stride + 1) * h + 1)) catch |err| switch (err) {
        error.ReadFailed => return inflate.err orelse error.ReadFailed,
        else => |e| return e,
    };
    defer a.free(raw);
    if (raw.len < (stride + 1) * h) return error.TruncatedPng;

    const pixels = try a.alloc(u8, stride * h);
    defer a.free(pixels);
    try unfilter(raw, pixels, stride, h, channels);

    const rgb = try a.alloc(u8, w * h * 3);
    for (0..w * h) |i| {
        const p = pixels[i * channels ..][0..channels];
        rgb[i * 3 ..][0..3].* = if (channels >= 3) p[0..3].* else .{ p[0], p[0], p[0] };
    }
    return .{ .w = w, .h = h, .rgb = rgb };
}

/// Undo PNG's per-row filters: `raw` is rows of a filter byte and `stride`
/// bytes, `out` the rows without it.
fn unfilter(raw: []const u8, out: []u8, stride: usize, h: usize, bpp: usize) !void {
    for (0..h) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const row = out[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) out[(y - 1) * stride ..][0..stride] else null;
        for (0..stride) |i| {
            const left: u8 = if (i >= bpp) row[i - bpp] else 0;
            const up: u8 = if (prev) |p| p[i] else 0;
            const upleft: u8 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
            row[i] = src[i] +% switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => paeth(left, up, upleft),
                else => return error.BadPngFilter,
            };
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// An 8-bit greyscale PNG of `pixels` (`w` × `h`), with stored (uncompressed)
/// deflate blocks.
fn encodeGreyPng(a: Allocator, pixels: []const u8, w: usize, h: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(w), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(h), .big);
    ihdr[8..13].* = .{ 8, 0, 0, 0, 0 }; // 8-bit grey, deflate, adaptive filters, not interlaced
    try chunk(a, &out, "IHDR", &ihdr);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    for (0..h) |y| {
        try raw.append(a, 0); // filter: none
        try raw.appendSlice(a, pixels[y * w ..][0..w]);
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(a);
    try z.appendSlice(a, &.{ 0x78, 0x01 });
    var rest = raw.items;
    while (true) {
        const n = @min(rest.len, 0xffff);
        const final = n == rest.len;
        try z.append(a, @intFromBool(final)); // BFINAL, BTYPE 00: stored
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], @intCast(n), .little);
        std.mem.writeInt(u16, lens[2..4], ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(a, &lens);
        try z.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (final) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw.items), .big);
    try z.appendSlice(a, &adler);
    try chunk(a, &out, "IDAT", z.items);
    try chunk(a, &out, "IEND", "");
    return out.toOwnedSlice(a);
}

fn chunk(a: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(a, &len);
    const start = out.items.len;
    try out.appendSlice(a, kind);
    try out.appendSlice(a, body);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(a, &crc);
}

// MARK: Alignment

/// The system's key names (identifier or label) and Byakaron's (its
/// accessibility labels) for the same key.
const same_key = std.StaticStringMap([]const u8).initComptime(.{
    .{ "shift", "shift" },
    .{ "delete", "delete" },
    .{ "more", "more: numbers" },
    .{ "emoji", "emoji" },
    .{ "space", "space" },
});

const Rect = [4]i64;

fn loadImage(t: *Tool, file: []const u8) !Image {
    const data = try Io.Dir.cwd().readFileAlloc(t.io, file, t.arena, .limited(512 * 1024 * 1024));
    return decodePng(t.arena, data) catch |err| {
        std.debug.print("{s}: {t}\n", .{ file, err });
        return err;
    };
}

/// Python's round(): halves to even.
fn roundEven(x: f64) i64 {
    const f = @floor(x);
    const d = x - f;
    var r = f;
    if (d > 0.5 or (d == 0.5 and @mod(f, 2) != 0)) r = f + 1;
    return @intFromFloat(r);
}

fn trunc(x: f64) i64 {
    return @intFromFloat(@trunc(x));
}

/// Per-channel median of the 5×5 pixels around `seed` (numpy's: the mean of
/// the middle two when even, at the image's edge).
fn medianAround(img: Image, seed: [2]i64) ?[3]f64 {
    var result: [3]f64 = undefined;
    for (0..3) |ch| {
        var vals: [25]u8 = undefined;
        var n: usize = 0;
        var y = @max(seed[1] - 2, 0);
        while (y < @min(seed[1] + 3, @as(i64, @intCast(img.h)))) : (y += 1) {
            var x = @max(seed[0] - 2, 0);
            while (x < @min(seed[0] + 3, @as(i64, @intCast(img.w)))) : (x += 1) {
                vals[n] = img.rgb[(@as(usize, @intCast(y)) * img.w + @as(usize, @intCast(x))) * 3 + ch];
                n += 1;
            }
        }
        if (n == 0) return null;
        std.mem.sort(u8, vals[0..n], {}, std.sort.asc(u8));
        result[ch] = if (n % 2 == 1) @floatFromInt(vals[n / 2]) else (@as(f64, @floatFromInt(vals[n / 2 - 1])) + @as(f64, @floatFromInt(vals[n / 2]))) / 2;
    }
    return result;
}

fn near(p: [3]i32, fill: [3]f64, tol: f64) bool {
    for (0..3) |ch| if (@abs(@as(f64, @floatFromInt(p[ch])) - fill[ch]) > tol) return false;
    return true;
}

/// The bounding box, in pixels, of the key at `seed`: the pixels joined to
/// it whose colour is within `tol` of the key's fill, inside `window`.
fn keyRect(a: Allocator, img: Image, seed: [2]i64, window: [4]i64) !?Rect {
    const tol = 28;
    const x0: i64 = @max(0, window[0]);
    const y0: i64 = @max(0, window[1]);
    const x1: i64 = @min(@as(i64, @intCast(img.w)), window[2]);
    const y1: i64 = @min(@as(i64, @intCast(img.h)), window[3]);
    if (x1 <= x0 or y1 <= y0) return null;
    const fill = medianAround(img, seed) orelse return null;
    const rw: usize = @intCast(x1 - x0);
    const rh: usize = @intCast(y1 - y0);
    const sx = seed[0] - x0;
    const sy = seed[1] - y0;
    if (sx < 0 or sy < 0 or sx >= rw or sy >= rh) return null;

    const seen = try a.alloc(bool, rw * rh);
    defer a.free(seen);
    @memset(seen, false);
    const inMask = struct {
        fn f(im: Image, fl: [3]f64, ox: i64, oy: i64, x: usize, y: usize) bool {
            return near(im.px(@as(usize, @intCast(ox)) + x, @as(usize, @intCast(oy)) + y), fl, tol);
        }
    }.f;
    const start = [2]usize{ @intCast(sx), @intCast(sy) };
    if (!inMask(img, fill, x0, y0, start[0], start[1])) return null;

    var queue: std.ArrayList([2]usize) = .empty;
    defer queue.deinit(a);
    try queue.append(a, start);
    seen[start[1] * rw + start[0]] = true;
    var minx = start[0];
    var maxx = start[0];
    var miny = start[1];
    var maxy = start[1];
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const x, const y = queue.items[head];
        minx = @min(minx, x);
        maxx = @max(maxx, x);
        miny = @min(miny, y);
        maxy = @max(maxy, y);
        const next = [4][2]i64{
            .{ @intCast(x), @as(i64, @intCast(y)) + 1 },
            .{ @intCast(x), @as(i64, @intCast(y)) - 1 },
            .{ @as(i64, @intCast(x)) + 1, @intCast(y) },
            .{ @as(i64, @intCast(x)) - 1, @intCast(y) },
        };
        for (next) |n| {
            if (n[0] < 0 or n[1] < 0 or n[0] >= rw or n[1] >= rh) continue;
            const nx: usize = @intCast(n[0]);
            const ny: usize = @intCast(n[1]);
            if (seen[ny * rw + nx] or !inMask(img, fill, x0, y0, nx, ny)) continue;
            seen[ny * rw + nx] = true;
            try queue.append(a, .{ nx, ny });
        }
    }
    return .{
        @as(i64, @intCast(minx)) + x0,
        @as(i64, @intCast(miny)) + y0,
        @as(i64, @intCast(maxx)) + x0 + 1,
        @as(i64, @intCast(maxy)) + y0 + 1,
    };
}

/// The keyboard's own colour: most common colour in its bottom rows'
/// middle (between the globe and the microphone); the lowest of equals.
fn background(a: Allocator, img: Image) ![3]i32 {
    const h = img.h;
    const w = img.w;
    const r0 = h - @as(usize, @intFromFloat(@trunc(@as(f64, @floatFromInt(h)) * 0.02)));
    const r1 = h - @as(usize, @intFromFloat(@trunc(@as(f64, @floatFromInt(h)) * 0.01)));
    const c0: usize = @intFromFloat(@trunc(@as(f64, @floatFromInt(w)) * 0.35));
    const c1: usize = @intFromFloat(@trunc(@as(f64, @floatFromInt(w)) * 0.65));
    var colours: std.ArrayList(u32) = .empty;
    defer colours.deinit(a);
    for (r0..r1) |y| for (c0..c1) |x| {
        const p = img.px(x, y);
        try colours.append(a, @as(u32, @intCast(p[0])) << 16 | @as(u32, @intCast(p[1])) << 8 | @as(u32, @intCast(p[2])));
    };
    if (colours.items.len == 0) return error.ImageTooSmall;
    std.mem.sort(u32, colours.items, {}, std.sort.asc(u32));
    var best = colours.items[0];
    var best_count: usize = 0;
    var i: usize = 0;
    while (i < colours.items.len) {
        var j = i;
        while (j < colours.items.len and colours.items[j] == colours.items[i]) j += 1;
        if (j - i > best_count) {
            best = colours.items[i];
            best_count = j - i;
        }
        i = j;
    }
    return .{ @intCast(best >> 16), @intCast((best >> 8) & 0xff), @intCast(best & 0xff) };
}

/// The first row, going down the middle from `from_y`, with the keyboard's
/// colour: the keyboard's top edge.
fn panelTop(a: Allocator, img: Image, from_y: i64) !?i64 {
    const tol = 6;
    const bg = try background(a, img);
    const h: i64 = @intCast(img.h);
    const w = img.w;
    for ([_]usize{ w / 2, w / 4, 3 * w / 4 }) |x| {
        var y = @max(from_y, -h);
        while (y < h) : (y += 1) {
            const row: usize = @intCast(if (y < 0) h + y else y); // Python's negative index
            const p = img.px(x, row);
            const ok = for (0..3) |ch| {
                if (@abs(p[ch] - bg[ch]) > tol) break false;
            } else true;
            if (ok) return y;
        }
    }
    return null;
}

const Frame = struct { x: f64, y: f64, w: f64, h: f64 };

fn frameOf(v: Value) Frame {
    return .{
        .x = num(get(v, "x")) orelse 0,
        .y = num(get(v, "y")) orelse 0,
        .w = num(get(v, "w")) orelse 0,
        .h = num(get(v, "h")) orelse 0,
    };
}

/// A point inside a key's drawn shape and clear of its label: a little in
/// from the left of its hit area, at mid height.
fn seedIn(f: Frame, scale: f64) [2]i64 {
    var x = f.x + f.w * 0.5 - @min(f.w * 0.32, f.w * 0.5 - 6);
    if (f.w > 80) x = f.x + 10; // space, return: wide labels sit in the middle
    const y = f.y + f.h * 0.5;
    return .{ roundEven(x * scale), roundEven(y * scale) };
}

/// `seed`, or the nearest pixel within `radius` that has the key colour.
fn findKeyNear(img: Image, seed: [2]i64, fill: [3]f64, radius: i64) ?[2]i64 {
    const w: i64 = @intCast(img.w);
    const h: i64 = @intCast(img.h);
    const inside = struct {
        fn f(im: Image, x: i64, y: i64, fl: [3]f64, ww: i64, hh: i64) bool {
            return y >= 0 and y < hh and x >= 0 and x < ww and near(im.px(@intCast(x), @intCast(y)), fl, 28);
        }
    }.f;
    if (inside(img, seed[0], seed[1], fill, w, h)) return seed;
    var r: i64 = 1;
    while (r < radius) : (r += 1) {
        for ([_][2]i64{ .{ r, 0 }, .{ -r, 0 }, .{ 0, r }, .{ 0, -r } }) |d| {
            if (inside(img, seed[0] + d[0], seed[1] + d[1], fill, w, h)) return .{ seed[0] + d[0], seed[1] + d[1] };
        }
    }
    return null;
}

fn windowOf(f: Frame, scale: f64, pad: i64) [4]i64 {
    return .{ trunc(f.x * scale) - pad, trunc(f.y * scale) - pad, trunc((f.x + f.w) * scale) + pad, trunc((f.y + f.h) * scale) + pad };
}

fn rectValue(a: Allocator, r: ?Rect) Value {
    const rect = r orelse return .null;
    var list = json.Array.init(a);
    for (rect) |v| list.append(jint(v)) catch oom();
    return .{ .array = list };
}

const Alignment = struct {
    report: json.ObjectMap,
    ok: bool,
    scale: f64,
    top_system: ?i64,
    top_byakaron: ?i64,
    top_delta: ?i64,
    /// Keys that are off: name and delta (null: not found).
    off: std.ArrayList(struct { key: []const u8, delta: ?Rect }),
    key_count: usize,
};

fn alignment(t: *Tool, folder: []const u8, keys: Value, tolerance: i64) !Alignment {
    const a = t.arena;
    const scale_value = get(get(keys, "device"), "scale") orelse return error.NoScale;
    const scale = num(scale_value) orelse return error.NoScale;
    const img_a = try loadImage(t, t.path(&.{ folder, "system.png" }));
    const img_b = try loadImage(t, t.path(&.{ folder, "byakaron.png" }));
    var byakaron: std.StringHashMapUnmanaged(Frame) = .empty;
    for (items(get(keys, "byakaron"))) |k| {
        const lower = std.ascii.allocLowerString(a, str(get(k, "name")) orelse continue) catch oom();
        try byakaron.put(a, lower, frameOf(k));
    }

    var result: Alignment = .{
        .report = object(),
        .ok = true,
        .scale = scale,
        .top_system = null,
        .top_byakaron = null,
        .top_delta = null,
        .off = .empty,
        .key_count = 0,
    };
    var key_list = json.Array.init(a);
    const system_keys = items(get(keys, "system"));
    for (system_keys) |key| {
        const name = str(get(key, "name")) orelse continue;
        const other_name = same_key.get(name) orelse (std.ascii.allocLowerString(a, name) catch oom());
        const length = std.unicode.utf8CountCodepoints(name) catch name.len;
        if (length != 1 and same_key.get(name) == null) continue; // return: its label is its only name on both keyboards
        const f = frameOf(key);
        const seed = seedIn(f, scale);
        const fill = medianAround(img_a, seed) orelse [3]f64{ -1000, -1000, -1000 };
        const pad = trunc(8 * scale);
        const window = windowOf(f, scale, pad);
        const rect_a = try keyRect(a, img_a, seed, window);
        const other = byakaron.get(other_name);
        const seed_b = findKeyNear(img_b, if (other) |o| seedIn(o, scale) else seed, fill, trunc(6 * scale));
        var window_b = if (other) |o| windowOf(o, scale, pad) else window;
        window_b = .{ @min(window[0], window_b[0]), @min(window[1], window_b[1]), @max(window[2], window_b[2]), @max(window[3], window_b[3]) };
        const rect_b = if (seed_b) |s| try keyRect(a, img_b, s, window_b) else null;

        var entry = object();
        put(a, &entry, "key", jstr(name));
        put(a, &entry, "system", rectValue(a, rect_a));
        put(a, &entry, "byakaron", rectValue(a, rect_b));
        var ok = false;
        var delta: ?Rect = null;
        if (rect_a != null and rect_b != null) {
            var d: Rect = undefined;
            for (0..4) |i| d[i] = rect_b.?[i] - rect_a.?[i];
            delta = d;
            put(a, &entry, "delta", rectValue(a, d)); // left, top, right, bottom, in pixels
            ok = for (d) |v| {
                if (@abs(v) > tolerance) break false;
            } else true;
        }
        put(a, &entry, "ok", .{ .bool = ok });
        if (!ok) try result.off.append(a, .{ .key = name, .delta = delta });
        result.ok = result.ok and ok;
        try key_list.append(.{ .object = entry });
        result.key_count += 1;
    }

    // The keyboard's top edge, from above its highest key.
    var top_key: ?f64 = null;
    for (system_keys) |k| {
        const f = frameOf(k);
        if (f.h > 0) top_key = if (top_key) |v| @min(v, f.y) else f.y;
    }
    const start = trunc(((top_key orelse return error.NoSystemKeys) - 120) * scale);
    result.top_system = try panelTop(a, img_a, start);
    result.top_byakaron = try panelTop(a, img_b, start);
    if (result.top_system != null and result.top_byakaron != null) result.top_delta = result.top_byakaron.? - result.top_system.?;
    var top = object();
    put(a, &top, "system", if (result.top_system) |v| jint(v) else .null);
    put(a, &top, "byakaron", if (result.top_byakaron) |v| jint(v) else .null);
    put(a, &top, "delta", if (result.top_delta) |v| jint(v) else .null);
    const top_ok = result.top_delta != null and @abs(result.top_delta.?) <= tolerance;
    put(a, &top, "ok", .{ .bool = top_ok });
    result.ok = result.ok and top_ok;

    put(a, &result.report, "scale", scale_value);
    put(a, &result.report, "keys", .{ .array = key_list });
    put(a, &result.report, "top", .{ .object = top });
    put(a, &result.report, "ok", .{ .bool = result.ok });
    return result;
}

// MARK: Flicker

const Frames = struct {
    w: usize,
    h: usize,
    times: []f64,
    /// Grey, `w` × `h` bytes each.
    data: []const u8,

    fn frame(f: Frames, i: usize) []const u8 {
        return f.data[i * f.w * f.h ..][0 .. f.w * f.h];
    }
};

/// Every frame the simulator recorded (it records only when the screen
/// changes), in grey at `width` pixels wide, with its time in seconds.
fn videoFrames(t: *Tool, video: []const u8, width: usize) !Frames {
    const script = t.path(&.{ t.kb, "Support", "e2e", "frames.swift" });
    const r = try std.process.run(t.arena, t.io, .{
        .argv = &.{ "xcrun", "swift", "-suppress-warnings", script, video, t.fmt("{d}", .{width}) },
        .environ_map = t.env,
        .stdout_limit = .unlimited,
        .reserve_amount = 16 * 1024 * 1024,
    });
    if (!r.term.success()) {
        std.debug.print("frames.swift failed:\n{s}\n", .{r.stderr});
        return error.FramesFailed;
    }
    const newline = std.mem.indexOfScalar(u8, r.stdout, '\n') orelse return error.FramesFailed;
    const header = try json.parseFromSliceLeaky(Value, t.arena, r.stdout[0..newline], .{});
    const w: usize = @intFromFloat(num(get(header, "width")) orelse return error.FramesFailed);
    const h: usize = @intFromFloat(num(get(header, "height")) orelse return error.FramesFailed);
    const times_v = items(get(header, "times"));
    const times = try t.arena.alloc(f64, times_v.len);
    for (times_v, times) |v, *out| out.* = num(v) orelse 0;
    const data = r.stdout[newline + 1 ..];
    if (w * h == 0 or data.len != w * h * times.len) return error.FramesFailed;
    return .{ .w = w, .h = h, .times = times, .data = data };
}

const FlickerResult = struct {
    report: json.ObjectMap,
    ok: ?bool,
    note: []const u8 = "",
    flicker_times: std.ArrayList(f64) = .empty,
};

fn flicker(t: *Tool, folder: []const u8, keys: Value, al: *const Alignment, threshold: f64) !FlickerResult {
    const a = t.arena;
    var marks: std.StringHashMapUnmanaged(f64) = .empty;
    const marks_text = try Io.Dir.cwd().readFileAlloc(t.io, t.path(&.{ folder, "marks.txt" }), a, .limited(1024 * 1024));
    var lines = std.mem.splitScalar(u8, marks_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = it.next().?;
        const value = it.next() orelse return error.BadMarks;
        if (it.next() != null) return error.BadMarks;
        try marks.put(a, name, try std.fmt.parseFloat(f64, value));
    }
    const recording = try readJson(t, t.path(&.{ folder, "recording.json" }));
    const started = num(get(recording, "started")) orelse return error.NoRecordingStart;
    const points_wide = num(get(get(keys, "device"), "width")) orelse return error.NoDeviceWidth;
    const width: usize = @intFromFloat(@trunc(points_wide)); // one pixel a point
    const frames = try videoFrames(t, t.path(&.{ folder, "switch.mp4" }), width);
    const scale = @as(f64, @floatFromInt(width)) / points_wide;

    // From a second before the tap (the recording's start is known to a
    // fraction of a second) to the last screenshot.
    const switch_at = marks.get("switch") orelse return error.NoSwitchMark;
    const done_at = marks.get("done") orelse return error.NoDoneMark;
    const begin = switch_at - started - 1.0;
    const end = done_at - started;
    var picked: std.ArrayList(usize) = .empty;
    var before: ?usize = null;
    for (frames.times, 0..) |time, i| {
        if (begin <= time and time <= end) try picked.append(a, i);
        if (time < begin) before = i;
    }
    if (before) |i| try picked.insert(a, 0, i); // the screen as it was going in
    var result: FlickerResult = .{ .report = object(), .ok = null };
    if (picked.items.len < 2) {
        result.note = "no frames recorded around the switch";
        put(a, &result.report, "ok", .null);
        put(a, &result.report, "note", jstr(result.note));
        return result;
    }

    // The keyboard, from a little above its top edge (it may grow) to above
    // the globe and microphone row (the globe lights up when tapped).
    const top_px: i64 = if (al.top_system) |s| (if (al.top_byakaron) |b| @min(s, b) else s) else al.top_byakaron orelse return error.NoTopEdge;
    const y0: i64 = @max(0, trunc(@as(f64, @floatFromInt(top_px)) / al.scale * scale) - trunc(24 * scale));
    const rows: i64 = @intCast(frames.h);
    const system_keys = items(get(keys, "system"));
    var y1: i64 = undefined;
    if (system_keys.len > 0) {
        var bottom: f64 = -std.math.inf(f64);
        for (system_keys) |k| {
            const f = frameOf(k);
            bottom = @max(bottom, f.y + f.h);
        }
        const device_h = num(get(get(keys, "device"), "height")) orelse return error.NoDeviceHeight;
        y1 = rows - trunc(device_h * scale - bottom * scale);
    } else y1 = rows - trunc(80 * scale);
    // Python's slice of rows y0:y1.
    const lo: usize = @intCast(@min(y0, rows));
    const hi_raw = if (y1 < 0) @max(0, rows + y1) else @min(y1, rows);
    const hi: usize = @intCast(@max(hi_raw, @as(i64, @intCast(lo))));
    const w = frames.w;
    const region = (hi - lo) * w;

    const fa = frames.frame(picked.items[0])[lo * w .. hi * w];
    const fb = frames.frame(picked.items[picked.items.len - 1])[lo * w .. hi * w];
    var denom: f64 = 0;
    for (fa, fb) |pa, pb| {
        const d = @as(f64, @floatFromInt(pb)) - @as(f64, @floatFromInt(pa));
        denom += d * d;
    }
    if (denom == 0) denom = 1.0;

    var timeline = json.Array.init(a);
    var bad: std.ArrayList(struct { frame: usize, entry: usize }) = .empty;
    for (picked.items) |i| {
        const f = frames.frame(i)[lo * w .. hi * w];
        var dot: f64 = 0;
        for (f, fa, fb) |pf, pa, pb| {
            dot += (@as(f64, @floatFromInt(pf)) - @as(f64, @floatFromInt(pa))) * (@as(f64, @floatFromInt(pb)) - @as(f64, @floatFromInt(pa)));
        }
        const alpha = std.math.clamp(dot / denom, 0, 1);
        const alpha32: f32 = @floatCast(alpha);
        var residual: usize = 0;
        for (f, fa, fb) |pf, pa, pb| {
            const af: f32 = @floatFromInt(pa);
            const diff: f32 = @as(f32, @floatFromInt(pb)) - af;
            if (@abs(@as(f32, @floatFromInt(pf)) - (af + alpha32 * diff)) > 24) residual += 1;
        }
        const off: f64 = if (region == 0) std.math.nan(f64) else @as(f64, @floatFromInt(residual)) / @as(f64, @floatFromInt(region));
        var entry = object();
        const time = frames.times[i] - (switch_at - started);
        put(a, &entry, "t", jround(a, time, 3));
        put(a, &entry, "blend", jround(a, alpha, 3));
        put(a, &entry, "off", jround(a, off, 5));
        if (off > threshold) try bad.append(a, .{ .frame = i, .entry = timeline.items.len });
        try timeline.append(.{ .object = entry });
    }
    for (bad.items[0..@min(8, bad.items.len)], 0..) |b, n| {
        const name = t.fmt("flicker-{d}.png", .{n});
        const png = try encodeGreyPng(a, frames.frame(b.frame), frames.w, frames.h);
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = t.path(&.{ folder, name }), .data = png });
        try timeline.items[b.entry].object.put(a, "image", jstr(name));
    }
    var flickers = json.Array.init(a);
    for (bad.items) |b| {
        try flickers.append(timeline.items[b.entry]);
        try result.flicker_times.append(a, std.fmt.parseFloat(f64, timeline.items[b.entry].object.get("t").?.number_string) catch 0);
    }
    var changed: i64 = 0;
    for (timeline.items) |e| {
        const blend = std.fmt.parseFloat(f64, e.object.get("blend").?.number_string) catch 0;
        if (0.02 < blend and blend < 0.98) changed += 1;
    }
    result.ok = bad.items.len == 0;
    put(a, &result.report, "ok", .{ .bool = result.ok.? });
    put(a, &result.report, "frames", jint(@intCast(timeline.items.len)));
    put(a, &result.report, "between", jint(changed));
    put(a, &result.report, "flickers", .{ .array = flickers });
    var region_v = json.Array.init(a);
    try region_v.appendSlice(&.{ jint(y0), jint(y1) });
    put(a, &result.report, "region", .{ .array = region_v });
    put(a, &result.report, "timeline", .{ .array = timeline });
    return result;
}

/// `+0.123` / `-1.000`.
fn signed3(a: Allocator, x: f64) []const u8 {
    return std.fmt.allocPrint(a, "{s}{d:.3}", .{ if (x >= 0 and !std.math.signbit(x)) "+" else "-", @abs(x) }) catch oom();
}

fn rectText(a: Allocator, r: Rect) []const u8 {
    return std.fmt.allocPrint(a, "[{d}, {d}, {d}, {d}]", .{ r[0], r[1], r[2], r[3] }) catch oom();
}

/// `ios_e2e <kb> analyze <folder> [--tolerance PX] [--flicker-threshold F]`:
/// checks one run of the switch test, writes report.json, exits 1 if either
/// check fails.
fn analyzeMain(t: *Tool, args: []const []const u8) u8 {
    var folder: ?[]const u8 = null;
    var tolerance: i64 = 1;
    var threshold: f64 = 0.01;
    var it: ArgIter = .{ .args = args };
    while (it.i < args.len) {
        const arg = args[it.i];
        it.i += 1;
        if (it.value(arg, "--tolerance")) |v| {
            tolerance = std.fmt.parseInt(i64, v, 10) catch usage("--tolerance needs a whole number of pixels", .{});
        } else if (it.value(arg, "--flicker-threshold")) |v| {
            threshold = std.fmt.parseFloat(f64, v) catch usage("--flicker-threshold needs a number", .{});
        } else if (folder == null and !std.mem.startsWith(u8, arg, "-")) {
            folder = arg;
        } else usage("unknown argument {s}", .{arg});
    }
    const dir = folder orelse usage("analyze needs a results folder", .{});
    return analyze(t, dir, tolerance, threshold) catch |err| {
        std.debug.print("analysis of {s} failed: {t}\n", .{ dir, err });
        return 1;
    };
}

fn analyze(t: *Tool, folder: []const u8, tolerance: i64, threshold: f64) !u8 {
    const a = t.arena;
    const keys = try readJson(t, t.path(&.{ folder, "keys.json" }));
    var al = try alignment(t, folder, keys, tolerance);
    var report = al.report;

    var fl: FlickerResult = undefined;
    if (exists(t, t.path(&.{ folder, "switch.mp4" })) and exists(t, t.path(&.{ folder, "marks.txt" }))) {
        fl = try flicker(t, folder, keys, &al, threshold);
    } else {
        fl = .{ .report = object(), .ok = null, .note = "no video" };
        put(a, &fl.report, "ok", .null);
        put(a, &fl.report, "note", jstr(fl.note));
    }
    put(a, &report, "flicker", .{ .object = fl.report });

    var parts: std.ArrayList([]const u8) = .empty;
    if (al.top_delta) |d| if (d != 0) try parts.append(a, t.fmt("top edge {s}{d}px", .{ if (d > 0) "+" else "-", @abs(d) }));
    if (al.off.items.len > 0) {
        var worst = al.off.items[0];
        var worst_v: i64 = -1;
        for (al.off.items) |k| {
            var m: i64 = 99;
            if (k.delta) |d| {
                m = 0;
                for (d) |v| m = @max(m, @as(i64, @intCast(@abs(v))));
            }
            if (m > worst_v) {
                worst = k;
                worst_v = m;
            }
        }
        try parts.append(a, t.fmt("{d}/{d} keys off (worst {s} {s} l,t,r,b px)", .{
            al.off.items.len, al.key_count, worst.key, if (worst.delta) |d| rectText(a, d) else "not found",
        }));
    }
    if (fl.ok == false) {
        var times: std.ArrayList([]const u8) = .empty;
        for (fl.flicker_times.items[0..@min(5, fl.flicker_times.items.len)]) |time| try times.append(a, t.fmt("{s}s", .{signed3(a, time)}));
        try parts.append(a, t.fmt("{d} flicker frames at {s}", .{ fl.flicker_times.items.len, try std.mem.join(a, ", ", times.items) }));
    } else if (fl.ok == null) {
        try parts.append(a, fl.note);
    }
    const summary = if (parts.items.len > 0) try std.mem.join(a, "; ", parts.items) else "lines up, no flicker";
    put(a, &report, "summary", jstr(summary));
    const ok = al.ok and fl.ok != false;
    put(a, &report, "ok", .{ .bool = ok });
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = t.path(&.{ folder, "report.json" }), .data = jsonText(a, .{ .object = report }, true) });

    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(t.io, &buf);
    try w.interface.print("{s}\n", .{summary});
    try w.interface.flush();
    return if (ok) 0 else 1;
}

// MARK: Tests

test globMatch {
    try std.testing.expect(globMatch("iPhone 17e", "iPhone 17e"));
    try std.testing.expect(!globMatch("iPhone 17", "iPhone 17e"));
    try std.testing.expect(!globMatch("iPhone 17e", "iPhone 17"));
    try std.testing.expect(globMatch("iPhone 1*", "iPhone 17 Pro Max"));
    try std.testing.expect(globMatch("iPhone 1*", "iPhone 11"));
    try std.testing.expect(!globMatch("iPhone 1*", "iPhone SE (3rd generation)"));
    try std.testing.expect(globMatch("iPhone Air*", "iPhone Air"));
    try std.testing.expect(globMatch("*Pro*", "iPhone 16 Pro Max"));
    try std.testing.expect(globMatch("iPhone 1?", "iPhone 16"));
    try std.testing.expect(!globMatch("iPhone 1?", "iPhone 16e"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("a*b*c", "aXXbYYbc"));
    try std.testing.expect(!globMatch("a*b*c", "aXXbYYb"));
    try std.testing.expect(globsMatch(default_devices, "iPhone Air"));
    try std.testing.expect(globsMatch(default_devices, "iPhone 16e"));
    try std.testing.expect(!globsMatch(default_devices, "iPad Pro 11-inch (M4)"));
    try std.testing.expect(globsMatch(" iPhone 17e , iPhone 16", "iPhone 16"));
}

test Version {
    const v = Version.parse;
    try std.testing.expectEqual(std.math.Order.gt, v("27.0").order(v("27+")));
    try std.testing.expectEqual(std.math.Order.eq, v("27").order(v("27+")));
    try std.testing.expectEqual(std.math.Order.lt, v("26.3.1").order(v("27+")));
    try std.testing.expectEqual(std.math.Order.gt, v("26.3.1").order(v("26.3")));
    try std.testing.expectEqual(@as(?u64, 17), v("iPhone 17 Pro").major());
}

test folderName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("iPhone-17-Pro-iOS-27.0", folderName(arena.allocator(), "iPhone 17 Pro iOS 27.0"));
    try std.testing.expectEqualStrings("iPhone-SE-3rd-generation-iOS-26.3.1", folderName(arena.allocator(), " iPhone SE (3rd generation) iOS 26.3.1"));
}

test roundEven {
    try std.testing.expectEqual(@as(i64, 2), roundEven(2.5));
    try std.testing.expectEqual(@as(i64, 4), roundEven(3.5));
    try std.testing.expectEqual(@as(i64, 3), roundEven(2.6));
    try std.testing.expectEqual(@as(i64, -2), roundEven(-2.5));
}

test "png: decode one PIL wrote" {
    // 5 × 4 RGB, pixel (x, y) = ((50x + 7y) % 256, (60y + 3x) % 256, 20xy % 256),
    // saved by PIL with optimize=True (compressed deflate, adaptive filters).
    const hex = "89504e470d0a1a0a0000000d4948445200000005000000040802000000c9516217000000224944415478da636460603062462016761b067666113882f3352008996fc3ce6c03006c9903b382255ab80000000049454e44ae426082";
    var data: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&data, hex);
    const a = std.testing.allocator;
    const img = try decodePng(a, &data);
    defer a.free(img.rgb);
    try std.testing.expectEqual(@as(usize, 5), img.w);
    try std.testing.expectEqual(@as(usize, 4), img.h);
    for (0..4) |y| for (0..5) |x| {
        const want = [3]i32{ @intCast((x * 50 + y * 7) % 256), @intCast((y * 60 + x * 3) % 256), @intCast((x * y * 20) % 256) };
        try std.testing.expectEqual(want, img.px(x, y));
    };
}

test "png: every filter type" {
    const w = 7;
    const h = 5;
    const bpp = 3;
    const stride = w * bpp;
    var pixels: [stride * h]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i *% 37 +% (i / 5) *% 101);
    // Row y uses filter y % 5.
    var raw: [(stride + 1) * h]u8 = undefined;
    for (0..h) |y| {
        const filter: u8 = @intCast(y % 5);
        raw[y * (stride + 1)] = filter;
        for (0..stride) |i| {
            const cur = pixels[y * stride + i];
            const left: u8 = if (i >= bpp) pixels[y * stride + i - bpp] else 0;
            const up: u8 = if (y > 0) pixels[(y - 1) * stride + i] else 0;
            const upleft: u8 = if (y > 0 and i >= bpp) pixels[(y - 1) * stride + i - bpp] else 0;
            raw[y * (stride + 1) + 1 + i] = cur -% switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                else => paeth(left, up, upleft),
            };
        }
    }
    var out: [stride * h]u8 = undefined;
    try unfilter(&raw, &out, stride, h, bpp);
    try std.testing.expectEqualSlices(u8, &pixels, &out);
    raw[0] = 9;
    try std.testing.expectError(error.BadPngFilter, unfilter(&raw, &out, stride, h, bpp));
}

test "png: grey round trip, with more than one stored block" {
    const a = std.testing.allocator;
    const w = 300;
    const h = 260; // > 65535 bytes of rows: two stored blocks
    const pixels = try a.alloc(u8, w * h);
    defer a.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @truncate(i * 7 + i / w);
    const png = try encodeGreyPng(a, pixels, w, h);
    defer a.free(png);
    const img = try decodePng(a, png);
    defer a.free(img.rgb);
    try std.testing.expectEqual(@as(usize, w), img.w);
    for (0..w * h) |i| try std.testing.expectEqual([3]u8{ pixels[i], pixels[i], pixels[i] }, img.rgb[i * 3 ..][0..3].*);
}

test "png: refuses what it cannot read" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotPng, decodePng(a, "GIF89a"));
    // A 16-bit PNG header.
    var png: std.ArrayList(u8) = .empty;
    defer png.deinit(a);
    try png.appendSlice(a, png_signature);
    try chunk(a, &png, "IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 16, 2, 0, 0, 0 });
    try std.testing.expectError(error.UnsupportedPngBitDepth, decodePng(a, png.items));
}
