//! In-memory AutoComplete backend: iAvro's dictionary, suffix and autocorrect
//! tables compiled into the binary.
//!
//! `lexicon.zon` (shape in `Lexicon.zig`) is generated at build time from the
//! pinned iAvro data and imported at compile time, already sorted, so there is
//! nothing to parse, index or allocate at startup: every lookup is a binary
//! search over the compiled-in slices.

const Mem = @This();

const std = @import("std");
const AutoComplete = @import("autocomplete");
const Lexicon = @import("Lexicon.zig");

pub const lexicon: Lexicon = @import("lexicon");

engine: AutoComplete,

/// Heap-allocate a Mem backend (stable pointer for the vtable ctx).
pub fn create(allocator: std.mem.Allocator) !*Mem {
    const self = try allocator.create(Mem);
    self.* = .{ .engine = AutoComplete.init(&vtable, self) };
    return self;
}

/// Frees the backend and what its engine learned; `allocator` must be the one
/// passed to `create` and to the engine's `suggest` / `select`.
pub fn destroy(self: *Mem, allocator: std.mem.Allocator) void {
    self.engine.deinit(allocator);
    allocator.destroy(self);
}

pub fn autoComplete(self: *Mem) *AutoComplete {
    return &self.engine;
}

const vtable: AutoComplete.VTable = .{
    .prefix_lookup = prefixLookup,
    .contains = containsWord,
    .dictionary_find = dictionaryFind,
    .suffix = suffixLookup,
    .autocorrect = autocorrectLookup,
};

/// Index of the first element of sorted `items` whose `keyOf` is not less than `key`.
fn lowerBound(comptime T: type, items: []const T, key: []const u8, comptime keyOf: fn (T) []const u8) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, keyOf(items[mid]), key) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn find(comptime T: type, items: []const T, key: []const u8, comptime keyOf: fn (T) []const u8) ?T {
    const i = lowerBound(T, items, key, keyOf);
    return if (i < items.len and std.mem.eql(u8, keyOf(items[i]), key)) items[i] else null;
}

fn wordKey(w: []const u8) []const u8 {
    return w;
}
fn tableKey(t: Lexicon.Table) []const u8 {
    return t.name;
}
fn suffixKey(s: Lexicon.Suffix) []const u8 {
    return s.latin;
}
fn autocorrectKey(a: Lexicon.Autocorrect) []const u8 {
    return a.from;
}

/// A table's words as the sorted list `Pattern.Matcher.collectSorted` walks.
const Words = struct {
    items: []const []const u8,
    pub fn len(self: Words) usize {
        return self.items.len;
    }
    pub fn get(self: Words, i: usize) []const u8 {
        return self.items[i];
    }
};

fn containsWord(_: *anyopaque, word: []const u8) bool {
    for (lexicon.tables) |t| {
        if (find([]const u8, t.words, word, wordKey) != null) return true;
    }
    return false;
}

fn dictionaryFind(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    tables: []const []const u8,
    matcher: *AutoComplete.Pattern.Matcher,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (tables) |name| {
        const t = find(Lexicon.Table, lexicon.tables, name, tableKey) orelse continue;
        try matcher.collectSorted(Words{ .items = t.words }, &out, allocator);
    }
    return out.items;
}

fn suffixLookup(_: *anyopaque, latin: []const u8) ?[]const u8 {
    const s = find(Lexicon.Suffix, lexicon.suffixes, latin, suffixKey) orelse return null;
    return s.bangla;
}

fn autocorrectLookup(_: *anyopaque, key: []const u8) ?AutoComplete.Autocorrect {
    const a = find(Lexicon.Autocorrect, lexicon.autocorrect, key, autocorrectKey) orelse return null;
    return .{ .text = a.to, .phonetic = a.phonetic };
}

/// Words starting with `prefix` across all tables, shortest first.
fn prefixLookup(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    limit: i64,
) ![]const AutoComplete.LexiconEntry {
    if (prefix.len == 0 or limit <= 0) return &.{};

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(allocator);
    for (lexicon.tables) |t| {
        var i = lowerBound([]const u8, t.words, prefix, wordKey);
        while (i < t.words.len and std.mem.startsWith(u8, t.words[i], prefix)) : (i += 1) {
            const gop = try seen.getOrPut(allocator, t.words[i]);
            if (!gop.found_existing) try matches.append(allocator, t.words[i]);
        }
    }

    std.mem.sort([]const u8, matches.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return a.len < b.len;
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    const n = @min(matches.items.len, @as(usize, @intCast(limit)));
    const out = try allocator.alloc(AutoComplete.LexiconEntry, n);
    for (out, matches.items[0..n]) |*o, w| o.* = .{ .word = w };
    return out;
}

// ------------ TESTING ------------
const testing = std.testing;

fn expectSuggest(m: *Mem, buffer: []const u8) !AutoComplete.Candidates {
    return m.autoComplete().suggest(testing.allocator, buffer);
}

test "lexicon is iAvro's data, sorted" {
    var total: usize = 0;
    for (lexicon.tables, 0..) |t, i| {
        if (i > 0) try testing.expect(std.mem.order(u8, lexicon.tables[i - 1].name, t.name) == .lt);
        for (t.words[1..], 0..) |w, j| try testing.expect(std.mem.order(u8, t.words[j], w) == .lt);
        total += t.words.len;
    }
    try testing.expect(total > 150_000);
    try testing.expect(find(Lexicon.Table, lexicon.tables, "khandatta", tableKey) != null);
    try testing.expect(suffixLookup(undefined, "er") != null);
    try testing.expect(autocorrectLookup(undefined, ":)") != null);
    try testing.expect(containsWord(undefined, "আমি"));
    try testing.expect(!containsWord(undefined, "ami"));
}

test "Avro suggestions: dictionary by edit distance, transliteration last" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    var c = try expectSuggest(m, "ami");
    defer c.deinit();
    try testing.expectEqualStrings("আমি", c.items[0]);
    try testing.expectEqual(@as(usize, 0), c.selected);
}

test "Avro suggestions: punctuation wraps every candidate" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    var c = try expectSuggest(m, "(ami).");
    defer c.deinit();
    for (c.items) |item| {
        try testing.expect(std.mem.startsWith(u8, item, "("));
        try testing.expect(std.mem.endsWith(u8, item, ")।"));
    }
}

test "Avro suggestions: suffix joins base words" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    var c = try expectSuggest(m, "bangladesher");
    defer c.deinit();
    var found = false;
    for (c.items) |item| found = found or std.mem.eql(u8, item, "বাংলাদেশের");
    try testing.expect(found);
}

test "Avro suggestions: the chosen candidate is highlighted next time" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    var first = try expectSuggest(m, "bhalo");
    defer first.deinit();
    try testing.expect(first.items.len > 2);
    const pick = first.items[2];
    try m.autoComplete().select(testing.allocator, "bhalo", pick);
    var again = try expectSuggest(m, "bhalo");
    defer again.deinit();
    try testing.expectEqualStrings(pick, again.items[again.selected]);

    const saved = try m.autoComplete().exportSelections(testing.allocator);
    defer testing.allocator.free(saved);
    const m2 = try Mem.create(testing.allocator);
    defer m2.destroy(testing.allocator);
    try m2.autoComplete().importSelections(testing.allocator, saved);
    var restored = try expectSuggest(m2, "bhalo");
    defer restored.deinit();
    try testing.expectEqualStrings(pick, restored.items[restored.selected]);
}

test "Avro suggestions: emoticon autocorrect" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    var c = try expectSuggest(m, ":)");
    defer c.deinit();
    try testing.expectEqualStrings(":)", c.items[0]);
}


test "Avro suggestions: golden first candidates for common words" {
    const m = try Mem.create(testing.allocator);
    defer m.destroy(testing.allocator);
    const cases = [_][2][]const u8{
        .{ "ami", "আমি" },       .{ "tumi", "তুমি" },     .{ "bangla", "বাংলা" },
        .{ "kemon", "কেমন" },    .{ "bhalo", "ভাল" },     .{ "ki", "কি" },
        .{ "amar", "আমার" },     .{ "desh", "দেশ" },      .{ "bhasha", "ভাষা" },
        .{ "shonar", "সোনার" },  .{ "gan", "গান" },       .{ "ekhon", "এখন" },
        .{ "kotha", "কথা" },     .{ "manush", "মানুষ" },  .{ "dhonnobad", "ধন্যবাদ" },
    };
    for (cases) |c| {
        var got = try expectSuggest(m, c[0]);
        defer got.deinit();
        testing.expectEqualStrings(c[1], got.items[0]) catch |err| {
            std.debug.print("{s}: want {s}, got {s}\n", .{ c[0], c[1], got.items[0] });
            return err;
        };
    }
}
