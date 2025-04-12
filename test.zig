const std = @import("std");
const expect = std.testing.expect;
const eql = std.mem.eql;
test "createFile, write, seekTo, read" {
    var content: []u8 = undefined;

    // for (content) |*c| {
    //     c.* = 'a';
    // }

    comptime {
        var buffer: [100]u8 = undefined;
        const bytes_read = try std.fs.cwd().readFile("junk_file.txt", &buffer);

        content = buffer[0..bytes_read];
    }
    try expect(eql(u8, content, "Hello File!"));
}

test "file stat" {
    const file = try std.fs.cwd().createFile(
        "junk_file2.txt",
        .{ .read = true },
    );
    defer file.close();
    const stat = try file.stat();
    try expect(stat.size == 0);
    try expect(stat.kind == .file);
    // try expect(stat.ctime <= std.time.nanoTimestamp());
    // try expect(stat.mtime <= std.time.nanoTimestamp());
    // try expect(stat.atime <= std.time.nanoTimestamp());
    try std.fs.cwd().deleteFile("junk_file2.txt");
}
