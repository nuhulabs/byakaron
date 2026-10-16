//! In-memory AutoComplete backend.
//!
//! The sorted lexicon is `@embedFile`'d from `dictionary_macos_sorted.txt`
//! (prepared from `packages/data/dictionary_macos.csv`). Word slices are built
//! once on first `create()` from that embedded text.

const Mem = @This();

const std = @import("std");
const AutoComplete = @import("autocomplete");

const dictionary_src = @embedFile("../assets/dictionary_macos_sorted.txt");

/// Process-lifetime sorted word list (slices into `dictionary_src`).
var words_storage: []const []const u8 = &.{};
var words_ready: bool = false;

engine: AutoComplete,

/// Heap-allocate a Mem backend (stable pointer for the vtable ctx).
pub fn create(allocator: std.mem.Allocator) !*Mem {
    // Global lexicon index is process-lifetime; always back it with c_allocator.
    try ensureWords(std.heap.c_allocator);
    const self = try allocator.create(Mem);
    self.* = .{ .engine = undefined };
    self.engine = AutoComplete.init(&vtable, self);
    return self;
}

pub fn destroy(self: *Mem, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

pub fn autoComplete(self: *Mem) *AutoComplete {
    return &self.engine;
}

pub fn wordCount() usize {
    return words_storage.len;
}

fn ensureWords(allocator: std.mem.Allocator) !void {
    if (words_ready) return;

    var count: usize = 0;
    var i: usize = 0;
    while (i < dictionary_src.len) {
        const start = i;
        while (i < dictionary_src.len and dictionary_src[i] != '\n') : (i += 1) {}
        if (i > start) count += 1;
        if (i < dictionary_src.len and dictionary_src[i] == '\n') i += 1;
    }

    const out = try allocator.alloc([]const u8, count);
    var n: usize = 0;
    i = 0;
    while (i < dictionary_src.len) {
        const start = i;
        while (i < dictionary_src.len and dictionary_src[i] != '\n') : (i += 1) {}
        if (i > start) {
            out[n] = dictionary_src[start..i];
            n += 1;
        }
        if (i < dictionary_src.len and dictionary_src[i] == '\n') i += 1;
    }

    words_storage = out;
    words_ready = true;
}

const vtable = AutoComplete.VTable{
    .prefix_lookup = prefixLookup,
    .contains = containsWord,
};

fn asSelf(ctx: *anyopaque) *Mem {
    return @ptrCast(@alignCast(ctx));
}

fn containsWord(ctx: *anyopaque, word: []const u8) bool {
    _ = asSelf(ctx);
    return binaryExact(words_storage, word);
}

fn prefixLookup(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    limit: i64,
) ![]const AutoComplete.LexiconEntry {
    _ = asSelf(ctx);
    if (prefix.len == 0 or limit <= 0) return &.{};

    const start = lowerBound(words_storage, prefix);
    const cap: usize = @intCast(limit);

    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);

    var i = start;
    const max_scan: usize = 128;
    while (i < words_storage.len and matches.items.len < max_scan) : (i += 1) {
        const w = words_storage[i];
        if (!std.mem.startsWith(u8, w, prefix)) break;
        try matches.append(allocator, w);
    }
    if (matches.items.len == 0) return &.{};

    // Stable sort by length ASC so natural base words beat long compounds
    std.mem.sort([]const u8, matches.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return a.len < b.len;
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    const take_count = @min(matches.items.len, cap);
    const out = try allocator.alloc(AutoComplete.LexiconEntry, take_count);
    for (0..take_count) |idx| {
        out[idx] = .{ .word = matches.items[idx], .frequency = 0 };
    }
    return out;
}

fn lowerBound(slice: []const []const u8, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = slice.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, slice[mid], key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn binaryExact(slice: []const []const u8, key: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = slice.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, slice[mid], key)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return true,
        }
    }
    return false;
}
