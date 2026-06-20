const std = @import("std");
const bangla_lib = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    var arena = init.arena;
    const allocator = arena.allocator();

    var mode: bangla_lib.TransliterationMode = .avro;

    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.skip();

    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    while (args.next()) |input| {
        if (std.mem.eql(u8, input, "--orva")) {
            mode = .orva;
            continue;
        }

        const result = switch (mode) {
            .avro => avro(allocator, input),
            .orva => orva(allocator, input),
            else => "Unsupported mode",
        };
        try stdout.writeStreamingAll(init.io, result);
        return;
    }

    try stderr.writeStreamingAll(init.io, "Press CTRL + D, once done:\n");
    var aw = std.Io.Writer.Allocating.init(allocator);
    try formatFromStdin(init.io, allocator, &aw.writer, mode);

    try stderr.writeStreamingAll(init.io, "\n");
    try stdout.writeStreamingAll(init.io, aw.written());
    return;
}

fn formatFromStdin(io: std.Io, allocator: std.mem.Allocator, writer: *std.Io.Writer, mode: bangla_lib.TransliterationMode) !void {
    var reader = std.Io.File.stdin().reader(io, &.{});
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    _ = try reader.interface.streamRemaining(&buffer.writer);
    const input = try buffer.toOwnedSliceSentinel(0);
    defer allocator.free(input);

    const result = switch (mode) {
        .avro => avro(allocator, input),
        .orva => orva(allocator, input),
        else => "Unsupported mode",
    };
    try writer.writeAll(result);
}

fn avro(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var transliteratior = bangla_lib.Transliteration.init(allocator, .avro);
    return transliteratior.transliterate(input);
}

fn orva(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    var transliteratior = bangla_lib.Transliteration.init(allocator, .orva);
    return transliteratior.transliterate(input);
}
