//! Bangla prefix autocomplete engine.
//!
//! Storage is injected via `VTable` so callers can back it with an in-memory
//! lexicon (`AutoComplete/Mem.zig`) or SQLite (`AutoComplete/Sqlite.zig`).

const AutoComplete = @This();

const std = @import("std");

pub const Suggestion = struct {
    word: []const u8,
    frequency: i64 = 0,
};

pub const LexiconEntry = struct {
    word: []const u8,
    frequency: i64 = 0,
};

pub const VTable = struct {
    /// Words that begin with `prefix`. Backend may return more than `limit`;
    /// `prefixSuggest` ranks and truncates.
    prefix_lookup: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        limit: i64,
    ) anyerror![]const LexiconEntry,

    contains: *const fn (ctx: *anyopaque, word: []const u8) bool,
};

vtable: *const VTable,
ctx: *anyopaque,

pub fn init(vtable: *const VTable, ctx: *anyopaque) AutoComplete {
    return .{ .vtable = vtable, .ctx = ctx };
}

pub fn contains(self: *const AutoComplete, word: []const u8) bool {
    if (word.len == 0) return false;
    return self.vtable.contains(self.ctx, word);
}

/// Ranked prefix completions: shortest first, then lexicographic, then frequency.
pub fn prefixSuggest(
    self: *AutoComplete,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    limit: i64,
) ![]const Suggestion {
    if (prefix.len == 0 or limit <= 0) return &.{};

    const fetch_limit = @max(limit * 6, limit);
    const rows = try self.vtable.prefix_lookup(self.ctx, allocator, prefix, fetch_limit);
    if (rows.len == 0) return &.{};

    var list: std.ArrayList(Suggestion) = .empty;
    try list.ensureTotalCapacity(allocator, rows.len);
    for (rows) |row| {
        try list.append(allocator, .{ .word = row.word, .frequency = row.frequency });
    }

    std.mem.sort(Suggestion, list.items, {}, struct {
        fn less(_: void, a: Suggestion, b: Suggestion) bool {
            if (a.frequency != b.frequency) return a.frequency > b.frequency;
            if (a.word.len != b.word.len) return a.word.len < b.word.len;
            return std.mem.order(u8, a.word, b.word) == .lt;
        }
    }.less);

    const cap: usize = @intCast(limit);
    if (list.items.len > cap) list.shrinkRetainingCapacity(cap);
    return try list.toOwnedSlice(allocator);
}
