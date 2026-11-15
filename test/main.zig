//! `zig build test`: one run over every test binary.
//!
//!   main --log-level=<level> <test binary>...
//!
//! Zig runs only a test build's root-module tests, so build.zig makes one test
//! binary per module (all with test/runner.zig). This runs them one after
//! another with `--report`: each lists its tests as they run and reports them
//! on stdout, and this prints one summary and one slowest list for all of them.

const std = @import("std");

const slowest_count = 15;

const Test = struct {
    status: []const u8,
    ns: u64,
    scope: []const u8,
    name: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var level_arg: []const u8 = "--log-level=info";
    var binaries: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--log-level=")) level_arg = arg else try binaries.append(arena, arg);
    }
    const level = std.meta.stringToEnum(std.log.Level, level_arg["--log-level=".len..]) orelse {
        std.debug.print("unknown log level {s} (debug, info, warn, err)\n", .{level_arg["--log-level=".len..]});
        std.process.exit(2);
    };
    const listing = @intFromEnum(level) >= @intFromEnum(std.log.Level.info);

    var tests: std.ArrayList(Test) = .empty;
    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var todo: usize = 0;
    var leak: usize = 0;
    var crashed: usize = 0;

    std.debug.print("\r\x1b[0K", .{});
    if (listing) std.debug.print("\x1b[1mRunning:\x1b[0m\n", .{});

    for (binaries.items) |bin| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ bin, "--report", level_arg },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buf);
        const out = try reader.interface.allocRemaining(arena, .unlimited);
        const term = try child.wait(io);

        var reported: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            const status = fields.next() orelse continue;
            const ns = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
            if (std.mem.eql(u8, status, "leak")) {
                leak += ns;
                continue;
            }
            const t: Test = .{ .status = status, .ns = ns, .scope = fields.next() orelse "", .name = fields.rest() };
            try tests.append(arena, t);
            reported += 1;
            if (std.mem.eql(u8, status, "pass")) pass += 1 else if (std.mem.eql(u8, status, "fail")) fail += 1 else if (std.mem.eql(u8, status, "skip")) skip += 1 else if (std.mem.eql(u8, status, "todo")) todo += 1;
        }
        // A panic or crash ends the binary before it reports.
        if (!term.success() and reported == 0) {
            crashed += 1;
            std.debug.print("\x1b[31m✗ {s} did not finish ({any})\x1b[0m\n", .{ std.fs.path.basename(bin), term });
        }
    }

    var total_ns: u64 = 0;
    for (tests.items) |t| total_ns += t.ns;
    const total = tests.items.len;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;

    std.debug.print("\n\x1b[32m{d:<3} pass\x1b[0m\n", .{pass});
    if (fail > 0) std.debug.print("\x1b[31m{d:<3} fail\x1b[0m\n", .{fail}) else std.debug.print("{d:<3} fail\n", .{fail});
    if (skip > 0) std.debug.print("\x1b[33m{d:<3} skipped\x1b[0m\n", .{skip});
    if (todo > 0) std.debug.print("\x1b[36m{d:<3} todo\x1b[0m\n", .{todo});
    if (leak > 0) std.debug.print("\x1b[31m{d:<3} leaked\x1b[0m\n", .{leak});
    if (crashed > 0) std.debug.print("\x1b[31m{d:<3} crashed\x1b[0m\n", .{crashed});
    std.debug.print("\x1b[90m{d} test{s} in {d} binaries | {d:.2}ms total\x1b[0m\n", .{ total, if (total != 1) "s" else "", binaries.items.len, total_ms });

    if (listing and total > 0) {
        std.mem.sort(Test, tests.items, {}, struct {
            fn more(_: void, a: Test, b: Test) bool {
                return a.ns > b.ns;
            }
        }.more);
        const n = @min(slowest_count, total);
        std.debug.print("\n\x1b[1mSlowest\x1b[0m \x1b[90m({d})\x1b[0m:\n", .{n});
        for (tests.items[0..n]) |t| {
            const ms = @as(f64, @floatFromInt(t.ns)) / 1_000_000.0;
            if (t.scope.len > 0) {
                std.debug.print("  {d:.2}ms\t\x1b[90m{s} > {s}\x1b[0m\n", .{ ms, t.scope, t.name });
            } else {
                std.debug.print("  {d:.2}ms\t\x1b[90m{s}\x1b[0m\n", .{ ms, t.name });
            }
        }
    }
    std.debug.print("\n", .{});
    std.process.exit(if (fail == 0 and leak == 0 and crashed == 0) 0 else 1);
}
