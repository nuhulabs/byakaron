//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const bangla_lib = @import("bangla_lib");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip the program name
    _ = args.skip();

    // Check if any argument was provided
    if (args.next()) |input| {
        var transliteratior = bangla_lib.Transliteration.init(allocator, .avro);
        const result = transliteratior.transliterate(input);
        defer allocator.free(result);

        std.debug.print("{s}\n", .{result});
    } else {
        std.debug.print("Usage: bangla <text>\nExample: bangla \"amar nam apon\"\n", .{});
        std.process.exit(1);
    }
}
