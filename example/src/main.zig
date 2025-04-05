//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const bangla = @import("bangla");
const yaml = @import("yaml");
const std = @import("std");
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const result = try bangla.Transliteration.transliterate("ami nurul", "avro", allocator);
    defer allocator.free(result);

    std.debug.print("{s}\n", .{result});
}
