//! `Store` over files in one data directory, created on first save. Writes go
//! to a temporary file that is renamed over the old one, so a reader never sees
//! half a file.

const FileStore = @This();

const std = @import("std");
const Store = @import("Store.zig");

io: std.Io,
/// Absolute path of the data directory (owned).
dir: []const u8,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !FileStore {
    return .{ .io = io, .dir = try gpa.dupe(u8, dir), .gpa = gpa };
}

pub fn deinit(self: *FileStore) void {
    self.gpa.free(self.dir);
}

pub fn store(self: *FileStore) Store {
    return .{ .ctx = self, .vtable = &.{ .load = load, .save = save }, .codec = &Store.Codec.json };
}

fn load(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const self: *FileStore = @ptrCast(@alignCast(ctx));
    const path = std.fs.path.join(self.gpa, &.{ self.dir, name }) catch return null;
    defer self.gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(16 * 1024 * 1024)) catch null;
}

fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) void {
    const self: *FileStore = @ptrCast(@alignCast(ctx));
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(self.io, self.dir) catch return;
    const path = std.fs.path.join(self.gpa, &.{ self.dir, name }) catch return;
    defer self.gpa.free(path);
    const tmp = std.mem.concat(self.gpa, u8, &.{ path, ".tmp" }) catch return;
    defer self.gpa.free(tmp);
    cwd.writeFile(self.io, .{ .sub_path = tmp, .data = bytes }) catch return;
    cwd.rename(tmp, cwd, path, self.io) catch {
        cwd.deleteFile(self.io, tmp) catch {};
    };
}

test FileStore {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const dir = try std.fs.path.join(testing.allocator, &.{ base, "byakaron" });
    defer testing.allocator.free(dir);

    var fs = try FileStore.init(testing.allocator, testing.io, dir);
    defer fs.deinit();
    const s = fs.store();
    try testing.expect(s.load(testing.allocator, Store.settings) == null);
    s.save(Store.settings, "{\"suggestions\":false}");
    s.save(Store.settings, "{\"suggestions\":true}");
    const got = s.load(testing.allocator, Store.settings).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"suggestions\":true}", got);
}
