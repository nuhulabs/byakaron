//! Bangla autocomplete engine.
//!
//! - `suggest` / `select`: the while-typing candidate list of OmicronLab Avro
//!   (iAvro `Suggestion.m` + `AvroKeyboardController.m`), from the Latin buffer.
//!   See "Avro suggestions" below.
//! - `prefixSuggest` / `contains`: plain lexicon lookups on Bangla text.
//!
//! Storage is injected via `VTable` so callers can back it with an in-memory
//! lexicon (`AutoComplete/Mem.zig`) or SQLite (`AutoComplete/Sqlite.zig`).

const AutoComplete = @This();

const std = @import("std");
const Transliteration = @import("transliteration");
pub const Pattern = @import("AutoComplete/Pattern.zig");

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

    /// iAvro `Database.find`: words of the named onset tables (`tablesFor`)
    /// that `matcher` accepts as a whole, in any order. Required by `suggest`.
    dictionary_find: ?*const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        tables: []const []const u8,
        matcher: *Pattern.Matcher,
    ) anyerror![]const []const u8 = null,

    /// iAvro `Database.banglaForSuffix`: Bangla for a lowercase Latin suffix.
    suffix: ?*const fn (ctx: *anyopaque, english: []const u8) ?[]const u8 = null,

    /// iAvro `AutoCorrect.find` table lookup (the key is already `fix`ed).
    autocorrect: ?*const fn (ctx: *anyopaque, key: []const u8) ?Autocorrect = null,
};

/// An autocorrect entry as stored: `phonetic` replacements are Avro phonetic
/// and are transliterated when used (iAvro transliterates them on load); the
/// rest (emoticons, …) are literal.
pub const Autocorrect = struct {
    text: []const u8,
    phonetic: bool,
};

vtable: *const VTable,
ctx: *anyopaque,

/// iAvro's weight cache: the candidate last chosen for a term (term → Bangla).
/// Owned with the allocator given to `suggest` / `select`; see `deinit`.
selections: std.StringHashMapUnmanaged([]const u8) = .empty,
avro: ?Transliteration = null,

pub fn init(vtable: *const VTable, ctx: *anyopaque) AutoComplete {
    return .{ .vtable = vtable, .ctx = ctx };
}

/// Free what `suggest` / `select` kept, with the allocator given to them.
pub fn deinit(self: *AutoComplete, gpa: std.mem.Allocator) void {
    self.clearSelections(gpa);
    self.selections.deinit(gpa);
    if (self.avro) |*t| t.deinit();
    self.avro = null;
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

// —— Avro suggestions ————————————————————————————————————————————————————————
//
// For a composed Latin buffer, iAvro shows (AvroKeyboardController
// `findCurrentCandidates`, Suggestion `getList`):
//
//   1. The buffer is split into leading punctuation, term, trailing punctuation
//      (`split`); the punctuation is transliterated and wrapped around
//      every candidate.
//   2. For the term: its autocorrect entry, then every dictionary word matching
//      the term's phonetic regex, sorted by edit distance to the term's plain
//      transliteration.
//   3. For every Latin suffix in iAvro's suffix table the term ends with, the
//      candidates of the part before it (step 2) joined with the Bangla suffix.
//   4. The plain transliteration, if not listed yet — so it is last, not first.
//   5. If the whole buffer (punctuation included) is an autocorrect entry such as
//      an emoticon, it goes first.
//
// The candidate to highlight is the one last chosen for the term (`select`),
// else the first. iAvro lists dictionary matches from an NSSet, so its order for
// words at equal distance is arbitrary; here ties keep table order, then byte
// order. Where iAvro's highlight index ignores the emoticon inserted at the top,
// it is shifted here to stay on the remembered word.

pub const Candidates = struct {
    arena: std.heap.ArenaAllocator,
    items: []const []const u8,
    /// Index into `items` to highlight.
    selected: usize,

    pub fn deinit(self: *Candidates) void {
        self.arena.deinit();
    }
};

pub const Options = struct {
    /// iAvro "IncludeDictionary". Off is plain phonetic mode: the only candidate
    /// is the term's transliteration (still wrapped in its punctuation).
    dictionary: bool = true,
};

/// Avro candidates for the composed Latin `buffer`. `gpa` also owns the engine's
/// learned selections and transliterator; use the same one throughout.
pub fn suggest(self: *AutoComplete, gpa: std.mem.Allocator, buffer: []const u8) !Candidates {
    return self.suggestWith(gpa, buffer, .{});
}

pub fn suggestWith(self: *AutoComplete, gpa: std.mem.Allocator, buffer: []const u8, options: Options) !Candidates {
    var result: Candidates = .{ .arena = .init(gpa), .items = &.{}, .selected = 0 };
    errdefer result.arena.deinit();
    const run = try self.compute(gpa, result.arena.allocator(), buffer, options);
    result.items = run.items;
    result.selected = run.selected;
    return result;
}

/// iAvro `candidateSelectionChanged`: remember `candidate` (as shown, with its
/// punctuation) as the choice for `buffer`'s term, so it is highlighted next
/// time. Choosing the first candidate when nothing was remembered is not stored.
pub fn select(self: *AutoComplete, gpa: std.mem.Allocator, buffer: []const u8, candidate: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const run = try self.compute(gpa, arena_state.allocator(), buffer, .{});
    if (run.split.term.len == 0 or run.items.len == 0) return;
    if (std.mem.eql(u8, candidate, run.items[0]) and run.remembered == null) return;

    const pre = run.prefix.len;
    const suf = run.suffix.len;
    if (candidate.len < pre + suf) return;
    try self.remember(gpa, run.split.term, candidate[pre .. candidate.len - suf]);
    // Reverse suffix caching: choosing "base + suffix" also remembers the base.
    if (run.bases.get(candidate)) |b| try self.remember(gpa, b.base, b.item);
}

pub const Selection = struct {
    term: []const u8 = "",
    word: []const u8 = "",
};

pub fn selectionList(self: *const AutoComplete, allocator: std.mem.Allocator) ![]Selection {
    const list = try allocator.alloc(Selection, self.selections.count());
    var it = self.selections.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) list[i] = .{ .term = e.key_ptr.*, .word = e.value_ptr.* };
    return list;
}

pub fn importSelectionList(self: *AutoComplete, gpa: std.mem.Allocator, list: []const Selection) !void {
    for (list) |sel| try self.remember(gpa, sel.term, sel.word);
}

/// The learned selections as a JSON object `{ "<term>": "<Bangla>" }` (iAvro
/// keeps them in weight.plist), for the caller to persist.
pub fn exportSelections(self: *const AutoComplete, allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    var it = self.selections.iterator();
    while (it.next()) |e| {
        try json.objectField(e.key_ptr.*);
        try json.write(e.value_ptr.*);
    }
    try json.endObject();
    return out.toOwnedSlice();
}

/// Merge selections saved by `exportSelections`.
pub fn importSelections(self: *AutoComplete, gpa: std.mem.Allocator, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSelections;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        try self.remember(gpa, e.key_ptr.*, e.value_ptr.string);
    }
}

fn remember(self: *AutoComplete, gpa: std.mem.Allocator, term: []const u8, word: []const u8) !void {
    const value = try gpa.dupe(u8, word);
    errdefer gpa.free(value);
    const gop = try self.selections.getOrPut(gpa, term);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, term) catch |err| {
            self.selections.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    gop.value_ptr.* = value;
}

const Base = struct { base: []const u8, item: []const u8 };

const Run = struct {
    split: Split,
    prefix: []const u8,
    suffix: []const u8,
    items: []const []const u8,
    selected: usize,
    remembered: ?usize,
    /// "base + suffix" word → its base term and base word (iAvro recentBaseCache).
    bases: std.StringHashMapUnmanaged(Base),
};

/// Forget every learned selection.
pub fn clearSelections(self: *AutoComplete, gpa: std.mem.Allocator) void {
    var it = self.selections.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    self.selections.clearRetainingCapacity();
}

/// The plain Avro transliteration of `latin` (allocated in `arena`).
pub fn transliterate(self: *AutoComplete, gpa: std.mem.Allocator, arena: std.mem.Allocator, latin: []const u8) ![]const u8 {
    if (latin.len == 0) return "";
    if (self.avro == null) self.avro = Transliteration.init(gpa, .avro);
    const out = self.avro.?.transliterate(latin);
    defer gpa.free(out);
    return arena.dupe(u8, out);
}

fn compute(self: *AutoComplete, gpa: std.mem.Allocator, arena: std.mem.Allocator, buffer: []const u8, options: Options) !Run {
    const parts = split(buffer);
    var run: Run = .{
        .split = parts,
        .prefix = try self.transliterate(gpa, arena, parts.prefix),
        .suffix = try self.transliterate(gpa, arena, parts.suffix),
        .items = &.{},
        .selected = 0,
        .remembered = null,
        .bases = .empty,
    };
    if (buffer.len == 0) return run;

    var list: std.ArrayList([]const u8) = .empty;
    if (parts.term.len > 0) {
        if (options.dictionary) {
            try self.termList(gpa, arena, parts.term, &list, &run.bases);
        } else {
            try list.append(arena, try self.transliterate(gpa, arena, parts.term));
        }
    }

    if (list.items.len == 0) {
        try list.append(arena, run.prefix);
        run.items = list.items;
        return run;
    }

    const prev: ?[]const u8 = if (options.dictionary) self.selections.get(parts.term) else null;
    if (prev) |p| {
        for (list.items, 0..) |item, i| if (std.mem.eql(u8, item, p)) {
            run.remembered = i;
            break;
        };
    }
    for (list.items) |*item| item.* = try std.mem.concat(arena, u8, &.{ run.prefix, item.*, run.suffix });
    if (options.dictionary and !std.mem.eql(u8, buffer, parts.term)) {
        if (try self.autocorrect(gpa, arena, buffer)) |smiley| {
            try list.insert(arena, 0, smiley);
            if (run.remembered) |*r| r.* += 1;
        }
    }
    run.items = list.items;
    run.selected = run.remembered orelse 0;
    return run;
}

/// iAvro `AutoCorrect.find`: `fix` the key (lowercase all but Avro's
/// case-sensitive letters), look it up, and transliterate a phonetic entry.
fn autocorrect(self: *AutoComplete, gpa: std.mem.Allocator, arena: std.mem.Allocator, term: []const u8) !?[]const u8 {
    const lookup = self.vtable.autocorrect orelse return null;
    const fixed = try arena.alloc(u8, term.len);
    for (term, fixed) |c, *f| f.* = if (std.mem.indexOfScalar(u8, "oiudgjnrstyz", std.ascii.toLower(c)) != null) c else std.ascii.toLower(c);
    const entry = lookup(self.ctx, fixed) orelse return null;
    return if (entry.phonetic) try self.transliterate(gpa, arena, entry.text) else entry.text;
}

/// Autocorrect entry, then dictionary matches by edit distance (iAvro's phonetic
/// cache entry for a term).
fn baseList(self: *AutoComplete, gpa: std.mem.Allocator, arena: std.mem.Allocator, term: []const u8, parsed: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const auto = try self.autocorrect(gpa, arena, term);

    const find = self.vtable.dictionary_find orelse {
        if (auto) |a| try out.append(arena, a);
        return out.items;
    };
    const regex = try Pattern.regexFor(arena, term);
    var matcher = try Pattern.Matcher.init(gpa, regex);
    defer matcher.deinit();
    const words = try find(self.ctx, arena, tablesFor(term[0]), &matcher);

    // Distinct words, first occurrence kept.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const Ranked = struct { word: []const u8, dist: usize, order: usize };
    var ranked: std.ArrayList(Ranked) = .empty;
    for (words) |w| {
        const gop = try seen.getOrPut(arena, w);
        if (gop.found_existing) continue;
        try ranked.append(arena, .{ .word = w, .dist = try levenshtein(arena, parsed, w), .order = ranked.items.len });
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            if (a.dist != b.dist) return a.dist < b.dist;
            return a.order < b.order;
        }
    }.less);

    // An autocorrect word that is also in the dictionary appears once, ranked.
    if (auto) |a| if (!seen.contains(a)) try out.append(arena, a);
    for (ranked.items) |r| try out.append(arena, r.word);
    return out.items;
}

fn termList(
    self: *AutoComplete,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    term: []const u8,
    list: *std.ArrayList([]const u8),
    bases: *std.StringHashMapUnmanaged(Base),
) !void {
    const parsed = try self.transliterate(gpa, arena, term);
    try list.appendSlice(arena, try self.baseList(gpa, arena, term, parsed));

    // Suggestions with suffix, longest base first.
    if (self.vtable.suffix) |suffix_lookup| {
        var already_selected = false;
        var i = term.len;
        while (i > 1) {
            i -= 1;
            if ((term[i] & 0xC0) == 0x80) continue; // not a character boundary
            const lower = try std.ascii.allocLowerString(arena, term[i..]);
            const suffix = suffix_lookup(self.ctx, lower) orelse continue;
            const base = term[0..i];
            const selected: ?[]const u8 = if (!already_selected) self.selections.get(base) else null;
            const base_parsed = try self.transliterate(gpa, arena, base);
            for (try self.baseList(gpa, arena, base, base_parsed)) |item| {
                if (std.mem.eql(u8, item, base)) continue; // English autocorrect entry
                const word = try joinSuffix(arena, item, suffix);
                try bases.put(arena, word, .{ .base = base, .item = item });
                if (listHas(list.items, word)) continue;
                // Intelligent selection: the word built on the base the user
                // chose before becomes this term's choice.
                if (!already_selected) if (selected) |sel| if (std.mem.eql(u8, item, sel)) {
                    if (self.selections.get(term) == null) try self.remember(gpa, term, word);
                    already_selected = true;
                };
                try list.append(arena, word);
            }
        }
    }

    if (!listHas(list.items, parsed)) try list.append(arena, parsed);
}

fn listHas(items: []const []const u8, word: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it, word)) return true;
    return false;
}

/// iAvro `Database.find`: the onset tables searched for a term starting with `c`.
pub fn tablesFor(c: u8) []const []const u8 {
    return switch (std.ascii.toLower(c)) {
        'a' => &.{ "a", "aa", "e", "oi", "o", "nya", "y" },
        'b' => &.{ "b", "bh" },
        'c' => &.{ "c", "ch", "k" },
        'd' => &.{ "d", "dh", "dd", "ddh" },
        'e' => &.{ "i", "ii", "e", "y" },
        'f' => &.{"ph"},
        'g' => &.{ "g", "gh", "j" },
        'h' => &.{"h"},
        'i' => &.{ "i", "ii", "y" },
        'j' => &.{ "j", "jh", "z" },
        'k' => &.{ "k", "kh" },
        'l' => &.{"l"},
        'm' => &.{ "h", "m" },
        'n' => &.{ "n", "nya", "nga", "nn" },
        'o' => &.{ "a", "u", "uu", "oi", "o", "ou", "y" },
        'p' => &.{ "p", "ph" },
        'q' => &.{"k"},
        'r' => &.{ "rri", "h", "r", "rr", "rrh" },
        's' => &.{ "s", "sh", "ss" },
        't' => &.{ "t", "th", "tt", "tth", "khandatta" },
        'u' => &.{ "u", "uu", "y" },
        'v' => &.{"bh"},
        'w' => &.{"o"},
        'x' => &.{ "e", "k" },
        'y' => &.{ "i", "y" },
        'z' => &.{ "h", "j", "jh", "z" },
        else => &.{},
    };
}

/// iAvro `NSString+Levenshtein` over code points (UTF-16 units in iAvro; the
/// same for Bangla, which is all in the BMP).
pub fn levenshtein(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    const x = try codepoints(allocator, a);
    defer allocator.free(x);
    const y = try codepoints(allocator, b);
    defer allocator.free(y);
    if (x.len == 0) return y.len;
    if (y.len == 0) return x.len;
    const row = try allocator.alloc(usize, y.len + 1);
    defer allocator.free(row);
    for (row, 0..) |*r, j| r.* = j;
    for (x, 1..) |cx, i| {
        var diag = row[0];
        row[0] = i;
        for (y, 1..) |cy, j| {
            const above = row[j];
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diag + @intFromBool(cx != cy));
            diag = above;
        }
    }
    return row[y.len];
}

fn codepoints(allocator: std.mem.Allocator, s: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(allocator);
    var it = (std.unicode.Utf8View.init(s) catch return out.toOwnedSlice(allocator)).iterator();
    while (it.nextCodepoint()) |cp| try out.append(allocator, cp);
    return out.toOwnedSlice(allocator);
}

/// iAvro `Suggestion.m`: join a dictionary word and a Bangla suffix — য় between
/// a vowel and a kar, ৎ → ত and ং → ঙ before the suffix.
pub fn joinSuffix(allocator: std.mem.Allocator, item: []const u8, suffix: []const u8) ![]u8 {
    const last = lastCodepoint(item) orelse return std.mem.concat(allocator, u8, &.{ item, suffix });
    const first = firstCodepoint(suffix) orelse return std.mem.concat(allocator, u8, &.{ item, suffix });
    const stem = item[0 .. item.len - last.len];
    if (isVowelBn(last.cp) and isKar(first)) return std.mem.concat(allocator, u8, &.{ item, "\u{09DF}", suffix });
    if (last.cp == 0x09CE) return std.mem.concat(allocator, u8, &.{ stem, "\u{09A4}", suffix });
    if (last.cp == 0x0982) return std.mem.concat(allocator, u8, &.{ stem, "\u{0999}", suffix });
    return std.mem.concat(allocator, u8, &.{ item, suffix });
}

fn isKar(cp: u21) bool {
    return switch (cp) {
        0x09BE, 0x09BF, 0x09C0, 0x09C1, 0x09C2, 0x09C3, 0x09C7, 0x09C8, 0x09CB, 0x09CC, 0x09C4 => true,
        else => false,
    };
}

fn isVowelBn(cp: u21) bool {
    return switch (cp) {
        0x0985, 0x0986, 0x0987, 0x0988, 0x0989, 0x098A, 0x098B, 0x098F, 0x0990, 0x0993, 0x0994, 0x098C, 0x09E1 => true,
        else => isKar(cp) and cp != 0x09C4,
    };
}

fn lastCodepoint(s: []const u8) ?struct { cp: u21, len: usize } {
    if (s.len == 0) return null;
    var i = s.len - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    const cp = std.unicode.utf8Decode(s[i..]) catch return null;
    return .{ .cp = cp, .len = s.len - i };
}

fn firstCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n > s.len) return null;
    return std.unicode.utf8Decode(s[0..n]) catch null;
}

/// The composed Latin buffer cut the way iAvro's AvroKeyboardController does with
/// its regex: leading punctuation, the term, trailing punctuation. Punctuation
/// is `:\``, `.\`` or one of ``-]\~!@#&*()_=+[{}'";<>/?|.,``. A `,,` (Avro's
/// explicit hasanta) right after the term stays in it.
pub const Split = struct {
    prefix: []const u8,
    term: []const u8,
    suffix: []const u8,
};

fn punctLen(s: []const u8, at: usize) usize {
    if (at + 1 < s.len and s[at + 1] == '`' and (s[at] == ':' or s[at] == '.')) return 2;
    if (std.mem.indexOfScalar(u8, "-]\\~!@#&*()_=+[{}'\";<>/?|.,", s[at]) != null) return 1;
    return 0;
}

fn allPunct(s: []const u8, from: usize) bool {
    var at = from;
    while (at < s.len) {
        const n = punctLen(s, at);
        if (n == 0) return false;
        at += n;
    }
    return true;
}

pub fn split(buffer: []const u8) Split {
    // Prefix, first alternative: the fewest punctuation tokens followed by ",,".
    var prefix_end: ?usize = null;
    {
        var at: usize = 0;
        while (true) {
            if (std.mem.startsWith(u8, buffer[at..], ",,")) {
                prefix_end = at;
                break;
            }
            if (at >= buffer.len) break;
            const n = punctLen(buffer, at);
            if (n == 0) break;
            at += n;
        }
    }
    // Otherwise as many punctuation tokens as possible.
    const p_end = prefix_end orelse blk: {
        var at: usize = 0;
        while (at < buffer.len) {
            const n = punctLen(buffer, at);
            if (n == 0) break;
            at += n;
        }
        break :blk at;
    };

    // Term: the shortest stretch (plus any ",," pairs right after it) such that
    // only punctuation remains.
    var core = p_end;
    while (core <= buffer.len) : (core += 1) {
        var j = core;
        while (std.mem.startsWith(u8, buffer[j..], ",,")) j += 2;
        if (allPunct(buffer, j)) return .{ .prefix = buffer[0..p_end], .term = buffer[p_end..j], .suffix = buffer[j..] };
    }
    return .{ .prefix = buffer[0..p_end], .term = buffer[p_end..], .suffix = "" };
}

// ------------ TESTING ------------
const testing = std.testing;

test {
    _ = Pattern;
}

test "split mirrors iAvro's prefix/term/suffix regex" {
    const s = split("(ami),");
    try testing.expectEqualStrings("(", s.prefix);
    try testing.expectEqualStrings("ami", s.term);
    try testing.expectEqualStrings("),", s.suffix);
    const h = split("k,,");
    try testing.expectEqualStrings("k,,", h.term);
    const p = split("...");
    try testing.expectEqualStrings("...", p.prefix);
    try testing.expectEqualStrings("", p.term);
}

test "joinSuffix" {
    const a = testing.allocator;
    const x = try joinSuffix(a, "ভালো", "ের");
    defer a.free(x);
    try testing.expectEqualStrings("ভালো\u{09DF}ের", x);
    const y = try joinSuffix(a, "বাংলা", "র");
    defer a.free(y);
    try testing.expectEqualStrings("বাংলার", y);
}

test "levenshtein" {
    try testing.expectEqual(@as(usize, 1), try levenshtein(testing.allocator, "আমি", "আমী"));
}
