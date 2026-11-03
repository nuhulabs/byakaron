//! The personal dictionary: words the user added, suggested after Avro's list
//! when they start with what is being typed. Stored one word per line,
//! byte-sorted (`user-words.txt`).
//!
//! Words are kept in canonical Bangla form (`normalize`): the nukta letters and
//! the two-part vowel signs are composed, so "য" + "়" and "য়" are one word.

const UserWords = @This();

const std = @import("std");

gpa: std.mem.Allocator,
/// Byte-sorted, distinct, normalized; each owned.
words: std.ArrayList([]u8) = .empty,

pub fn init(gpa: std.mem.Allocator) UserWords {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *UserWords) void {
    self.clear();
    self.words.deinit(self.gpa);
}

fn clear(self: *UserWords) void {
    for (self.words.items) |w| self.gpa.free(w);
    self.words.clearRetainingCapacity();
}

/// Replace the list with the words in `text` (one per line).
pub fn load(self: *UserWords, text: []const u8) !void {
    self.clear();
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| _ = try self.add(line);
}

/// The list as file text (caller frees).
pub fn serialize(self: UserWords, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (self.words.items) |w| {
        try out.appendSlice(allocator, w);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn index(self: UserWords, word: []const u8) struct { found: bool, at: usize } {
    var lo: usize = 0;
    var hi: usize = self.words.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, self.words.items[mid], word)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return .{ .found = true, .at = mid },
        }
    }
    return .{ .found = false, .at = lo };
}

/// Add `word` (normalized). False if it was already there or is not a word.
pub fn add(self: *UserWords, word: []const u8) !bool {
    const norm = try normalize(self.gpa, word) orelse return false;
    const pos = self.index(norm);
    if (pos.found) {
        self.gpa.free(norm);
        return false;
    }
    try self.words.insert(self.gpa, pos.at, norm);
    return true;
}

/// Remove `word`. False if it was not there.
pub fn remove(self: *UserWords, word: []const u8) !bool {
    const norm = try normalize(self.gpa, word) orelse return false;
    defer self.gpa.free(norm);
    const pos = self.index(norm);
    if (!pos.found) return false;
    self.gpa.free(self.words.orderedRemove(pos.at));
    return true;
}

pub fn contains(self: UserWords, word: []const u8) bool {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const norm = (normalize(fba.allocator(), word) catch return false) orelse return false;
    return self.index(norm).found;
}

/// Up to `limit` words starting with `prefix`, in byte order (slices into the list).
pub fn prefix(self: UserWords, allocator: std.mem.Allocator, start: []const u8, limit: usize) ![]const []const u8 {
    const norm = try normalize(allocator, start) orelse return &.{};
    defer allocator.free(norm);
    var out: std.ArrayList([]const u8) = .empty;
    var i = self.index(norm).at;
    while (i < self.words.items.len and out.items.len < limit) : (i += 1) {
        const w = self.words.items[i];
        if (!std.mem.startsWith(u8, w, norm)) break;
        try out.append(allocator, w);
    }
    return out.toOwnedSlice(allocator);
}

/// `word` trimmed and in canonical Bangla form (caller frees), or null if it is
/// empty, not UTF-8, or contains a line break. Composes ড়/ঢ়/য় from letter +
/// nukta and ো/ৌ from their two-part spellings: the canonical compositions that
/// occur in Bangla text (NFC for this script).
pub fn normalize(allocator: std.mem.Allocator, word: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, word, " \t\r\n");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) return null;
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev: ?u21 = null;
    var it = std.unicode.Utf8View.initUnchecked(trimmed).iterator();
    while (it.nextCodepoint()) |cp| {
        if (prev) |p| if (compose(p, cp)) |c| {
            out.shrinkRetainingCapacity(out.items.len - (std.unicode.utf8CodepointSequenceLength(p) catch unreachable));
            try appendCodepoint(allocator, &out, c);
            prev = c;
            continue;
        };
        try appendCodepoint(allocator, &out, cp);
        prev = cp;
    }
    return try out.toOwnedSlice(allocator);
}

fn compose(a: u21, b: u21) ?u21 {
    return switch (b) {
        0x09BC => switch (a) { // nukta
            0x09A1 => 0x09DC, // ড়
            0x09A2 => 0x09DD, // ঢ়
            0x09AF => 0x09DF, // য়
            else => null,
        },
        0x09BE => if (a == 0x09C7) 0x09CB else null, // ে + া → ো
        0x09D7 => if (a == 0x09C7) 0x09CC else null, // ে + ৗ → ৌ
        else => null,
    };
}

fn appendCodepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(allocator, buf[0..n]);
}

// ------------ TESTING ------------
const testing = std.testing;

test "normalize composes nukta and two-part vowel signs" {
    const a = testing.allocator;
    const n = (try normalize(a, "  কাঠাল\u{09AF}\u{09BC} ")).?;
    defer a.free(n);
    try testing.expectEqualStrings("কাঠাল\u{09DF}", n);
    const o = (try normalize(a, "ক\u{09C7}\u{09BE}")).?;
    defer a.free(o);
    try testing.expectEqualStrings("কো", o);
    try testing.expect(try normalize(a, "   ") == null);
    try testing.expect(try normalize(a, "\xff") == null);
}

test "add, remove, prefix, round trip" {
    const a = testing.allocator;
    var u = UserWords.init(a);
    defer u.deinit();
    try testing.expect(try u.add("বাংলাদেশ"));
    try testing.expect(try u.add("বাংলা"));
    try testing.expect(!try u.add("বাংলা "));
    try testing.expect(try u.add("আমি"));
    try testing.expect(u.contains("বাংলা"));

    const p = try u.prefix(a, "বাং", 5);
    defer a.free(p);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expectEqualStrings("বাংলা", p[0]);

    const text = try u.serialize(a);
    defer a.free(text);
    var v = UserWords.init(a);
    defer v.deinit();
    try v.load(text);
    try testing.expectEqual(@as(usize, 3), v.words.items.len);
    try testing.expect(try v.remove("আমি"));
    try testing.expect(!try v.remove("আমি"));
    try testing.expect(!v.contains("আমি"));
}
