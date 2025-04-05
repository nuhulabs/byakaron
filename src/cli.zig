const std = @import("std");
const lib = @import("bangla_zig_lib");
const Transliteration = lib.transliteration.Transliteration;

pub fn main() !void {
    // Get an allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Get stdout
    const stdout = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout);
    const writer = bw.writer();

    // Help message
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try writer.print("Usage: {s} [text] [--mode=avro]\n", .{args[0]});
        try writer.print("       {s} --file=input.txt [--mode=avro] [--output=output.txt]\n\n", .{args[0]});
        try writer.print("Options:\n", .{});
        try writer.print("  --mode=MODE     Transliteration mode (default: avro, available: avro)\n", .{});
        try writer.print("  --file=FILE     Read input from file instead of command line\n", .{});
        try writer.print("  --output=FILE   Write output to file instead of stdout\n", .{});
        try writer.print("  --help, -h      Show this help message\n", .{});
        try bw.flush();
        return;
    }

    // Default options
    var mode: []const u8 = "avro";
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var input_text: ?[]const u8 = null;

    // Parse command line arguments
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            mode = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            input_file = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_file = arg[9..];
        } else if (input_text == null and !std.mem.startsWith(u8, arg, "--")) {
            input_text = arg;
        }
    }

    var text: []const u8 = undefined;
    var text_owned = false;

    // Read input from file or command line
    if (input_file) |file| {
        const file_content = try std.fs.cwd().readFileAlloc(allocator, file, std.math.maxInt(usize));
        text = file_content;
        text_owned = true;
    } else if (input_text) |cmd_text| {
        text = cmd_text;
    } else {
        try writer.print("Error: No input provided. Use --help for usage information.\n", .{});
        try bw.flush();
        return;
    }
    defer if (text_owned) allocator.free(text);

    // Perform transliteration
    const result = try Transliteration.transliterate(text, mode, allocator);
    defer allocator.free(result);

    // Write output to file or stdout
    if (output_file) |file| {
        var file_handle = try std.fs.cwd().createFile(file, .{});
        defer file_handle.close();
        try file_handle.writeAll(result);
    } else {
        try writer.print("{s}\n", .{result});
        try bw.flush();
    }
}
