//! Build-time downloader: `fetch <url> <out>`.
//!
//! Run from `zig build db` with the URL as an argument, so the build cache keys
//! the download on it and a given URL is only fetched once.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <url> <out>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const url = args[1];

    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buf: [256 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    std.debug.print("fetching {s}\n", .{url});
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    if (result.status != .ok) {
        std.debug.print("error: {s} → HTTP {d}\n", .{ url, @backingInt(result.status) });
        return error.HttpError;
    }
    try writer.interface.flush();
}
