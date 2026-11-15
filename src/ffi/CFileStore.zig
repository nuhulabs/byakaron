//! `Store` over files in one data directory, like `Composer.FileStore`, through
//! libc instead of std.Io: the iOS build has no std.Io.Threaded (see ffi.zig).
//! On iOS the directory is in the App Group container the keyboard extension
//! and its app share. Writes go to a temporary file renamed over the old one.

const CFileStore = @This();

const std = @import("std");
const Store = @import("composer").Store;

const FILE = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn remove(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const max_size = 16 * 1024 * 1024;

/// Absolute path of the data directory (owned).
dir: []const u8,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, dir: []const u8) !CFileStore {
    return .{ .dir = try gpa.dupe(u8, dir), .gpa = gpa };
}

pub fn deinit(self: *CFileStore) void {
    self.gpa.free(self.dir);
}

pub fn store(self: *CFileStore) Store {
    return .{ .ctx = self, .vtable = &.{ .load = load, .save = save }, .codec = &Store.Codec.json };
}

fn pathZ(self: *CFileStore, name: []const u8, suffix: []const u8) ?[:0]u8 {
    return std.mem.concatWithSentinel(self.gpa, u8, &.{ self.dir, "/", name, suffix }, 0) catch null;
}

fn load(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const self: *CFileStore = @ptrCast(@alignCast(ctx));
    const path = self.pathZ(name, "") orelse return null;
    defer self.gpa.free(path);
    const f = fopen(path, "rb") orelse return null;
    defer _ = fclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        if (out.items.len + n > max_size) {
            out.deinit(allocator);
            return null;
        }
        out.appendSlice(allocator, buf[0..n]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn save(ctx: *anyopaque, name: []const u8, bytes: []const u8) void {
    const self: *CFileStore = @ptrCast(@alignCast(ctx));
    const dir = self.gpa.dupeSentinel(u8, self.dir, 0) catch return;
    defer self.gpa.free(dir);
    _ = mkdir(dir, 0o755); // fails harmlessly if it exists
    const path = self.pathZ(name, "") orelse return;
    defer self.gpa.free(path);
    const tmp = self.pathZ(name, ".tmp") orelse return;
    defer self.gpa.free(tmp);
    const f = fopen(tmp, "wb") orelse return;
    const written = fwrite(bytes.ptr, 1, bytes.len, f);
    if (fclose(f) != 0 or written != bytes.len or rename(tmp, path) != 0) _ = remove(tmp);
}

test CFileStore {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const dir = try std.fs.path.join(testing.allocator, &.{ base, "byakaron" });
    defer testing.allocator.free(dir);

    var fs = try CFileStore.init(testing.allocator, dir);
    defer fs.deinit();
    const s = fs.store();
    try testing.expect(s.load(testing.allocator, Store.settings) == null);
    s.save(Store.settings, "{\"suggestions\":false}");
    s.save(Store.settings, "{\"suggestions\":true}");
    const got = s.load(testing.allocator, Store.settings).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"suggestions\":true}", got);
}
