//! Where a `Composer` keeps its user data: small named text blobs —
//! `settings.json`, `selections.json` (learned Avro choices) and
//! `user-words.txt` (personal dictionary). `FileStore` keeps them as files in
//! one data directory (native keyboards and apps); the web backs it with `zx.kv`;
//! `Memory` is for tests.
//!
//! Blobs are read again whenever a word starts, so a change saved by another
//! process (the settings app, another keyboard instance) applies to the next
//! word without any IPC.

const Store = @This();

const std = @import("std");

pub const settings = "settings.json";
pub const selections = "selections.json";
pub const user_words = "user-words.txt";

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// The blob's bytes (allocated with `allocator`), or null if absent.
    load: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]u8,
    /// Replace the blob, atomically where the medium allows. Best effort.
    save: *const fn (ctx: *anyopaque, name: []const u8, bytes: []const u8) void,
};

pub fn load(self: Store, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return self.vtable.load(self.ctx, allocator, name);
}

pub fn save(self: Store, name: []const u8, bytes: []const u8) void {
    self.vtable.save(self.ctx, name, bytes);
}

/// In-memory store (tests, or a platform without persistence).
pub const Memory = struct {
    gpa: std.mem.Allocator,
    blobs: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Memory {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Memory) void {
        var it = self.blobs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.blobs.deinit(self.gpa);
    }

    pub fn store(self: *Memory) Store {
        return .{ .ctx = self, .vtable = &.{ .load = memLoad, .save = memSave } };
    }

    fn memLoad(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        const bytes = self.blobs.get(name) orelse return null;
        return allocator.dupe(u8, bytes) catch null;
    }

    fn memSave(ctx: *anyopaque, name: []const u8, bytes: []const u8) void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, bytes) catch return;
        const gop = self.blobs.getOrPut(self.gpa, name) catch {
            self.gpa.free(copy);
            return;
        };
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch {
                self.blobs.removeByPtr(gop.key_ptr);
                self.gpa.free(copy);
                return;
            };
        }
        gop.value_ptr.* = copy;
    }
};

test Memory {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    const s = m.store();
    try std.testing.expect(s.load(std.testing.allocator, settings) == null);
    s.save(settings, "{}");
    s.save(settings, "{\"a\":1}");
    const got = s.load(std.testing.allocator, settings).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"a\":1}", got);
}
