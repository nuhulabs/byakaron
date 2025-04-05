//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("bangla_zig_lib");
const Transliteration = lib.transliteration.Transliteration;

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
pub fn main() !void {
    std.debug.print("Bangla.zig\n", .{});
}
