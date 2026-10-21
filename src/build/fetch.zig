//! Build-time downloader: `fetch <url> <out> [sha256]`.
//!
//! Run from the build with the URL as an argument, so the build cache keys the
//! download on it and a given URL is only fetched once. With a SHA-256 the
//! download is verified and the step fails on mismatch.
//!
//! Mirrors sometimes accept a connection and then never answer, so an attempt
//! that makes no progress for `stall_timeout` is cancelled and retried on a
//! fresh connection. Each attempt writes its own `<out>.partN`, renamed into
//! place on success, so a cancelled attempt can never touch the result.

const std = @import("std");
const Io = std.Io;

const max_attempts = 5;
const stall_timeout: Io.Duration = .fromSeconds(30);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) {
        std.debug.print("usage: {s} <url> <out> [sha256]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const url = args[1];
    const out = args[2];

    const cwd = Io.Dir.cwd();
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        std.debug.print("fetching {s}\n", .{url});
        const part = try std.fmt.allocPrint(arena, "{s}.part{d}", .{ out, attempt });
        if (attemptDownload(init.gpa, io, url, part)) |_| {
            try cwd.rename(part, cwd, out, io);
            break;
        } else |err| {
            if (attempt == max_attempts) return err;
            std.debug.print("  attempt {d} failed ({t}); retrying\n", .{ attempt, err });
        }
    }

    if (args.len == 4) try verify(io, out, args[3]);
}

const Race = union(enum) {
    download: anyerror!void,
    stalled: Io.Cancelable!void,
};

/// One download attempt, cancelled if the output file stops growing.
fn attemptDownload(gpa: std.mem.Allocator, io: Io, url: []const u8, out: []const u8) !void {
    var buf: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buf);
    try select.concurrent(.download, download, .{ gpa, io, url, out });
    try select.concurrent(.stalled, watchdog, .{ io, out });
    const first = try select.await();
    _ = select.cancel();
    return switch (first) {
        .download => |result| result,
        .stalled => error.Stalled,
    };
}

fn download(gpa: std.mem.Allocator, io: Io, url: []const u8, out: []const u8) anyerror!void {
    var file = try Io.Dir.cwd().createFile(io, out, .{});
    defer file.close(io);
    // Flushed in 256 KiB chunks, which is what `watchdog` sees as progress.
    var buf: [256 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buf);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &file_writer.interface,
    });
    if (result.status != .ok) {
        std.debug.print("error: {s} → HTTP {d}\n", .{ url, @backingInt(result.status) });
        return error.HttpError;
    }
    try file_writer.interface.flush();
}

/// Returns once `out` has not grown for `stall_timeout`.
fn watchdog(io: Io, out: []const u8) Io.Cancelable!void {
    var last: u64 = 0;
    while (true) {
        try io.sleep(stall_timeout, .awake);
        const size = if (Io.Dir.cwd().statFile(io, out, .{})) |st| st.size else |_| 0;
        if (size == last) return;
        last = size;
    }
}

fn verify(io: Io, path: []const u8, expected_hex: []const u8) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual_hex, expected_hex)) {
        std.debug.print("error: {s}: sha256 {s}, expected {s}\n", .{ path, &actual_hex, expected_hex });
        return error.ChecksumMismatch;
    }
}
