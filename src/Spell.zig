const Spell = @This();

const std = @import("std");
const tokenization = @import("tokenization");

const Tokenizer = tokenization.Tokenizer;

pub const Suggestion = struct {
    word: []const u8,
    frequency: i64,
    distance: usize = 0,
    score: i64 = 0,
};

pub const TokenResult = struct {
    token: []const u8,
    known: bool,
    suggestions: []const Suggestion,
};

pub const LexiconEntry = struct {
    word: []const u8,
    frequency: i64,
};

pub const DeleteLookupHit = struct {
    delete_key: []const u8,
    word: []const u8,
    frequency: i64,
};

pub const ConfusionRule = struct {
    from_g: []const u8,
    to_g: []const u8,
    weight: f64,
};

pub const VTable = struct {
    lookup_words: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        words: []const []const u8,
    ) anyerror![]const LexiconEntry,

    lookup_deletes: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        delete_keys: []const []const u8,
    ) anyerror![]const DeleteLookupHit,

    prefix_suggest: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        limit: i64,
    ) anyerror![]const LexiconEntry,

    next_word_suggest: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        previous_word: []const u8,
        limit: i64,
    ) anyerror![]const LexiconEntry,

    trigram_next_word_suggest: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        w1: []const u8,
        w2: []const u8,
        limit: i64,
    ) anyerror![]const LexiconEntry,

    /// Bigram frequencies for fixed `left` × each of `rights` (hits only).
    /// `LexiconEntry.word` is the right word; `.frequency` is the bigram count.
    lookup_bigrams: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        left: []const u8,
        rights: []const []const u8,
    ) anyerror![]const LexiconEntry,

    /// Bigram frequencies for each of `lefts` × fixed `right` (hits only).
    /// `LexiconEntry.word` is the left word; `.frequency` is the bigram count.
    lookup_bigrams_right: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        lefts: []const []const u8,
        right: []const u8,
    ) anyerror![]const LexiconEntry,

    /// Trigram frequencies for fixed `(w1, w2)` × each of `w3s` (hits only).
    /// `LexiconEntry.word` is w3; `.frequency` is the trigram count.
    lookup_trigrams: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        w1: []const u8,
        w2: []const u8,
        w3s: []const []const u8,
    ) anyerror![]const LexiconEntry,

    load_confusions: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror![]const ConfusionRule,
};

vtable: *const VTable,
ctx: *anyopaque,
confusions: ConfusionIndex = .{},

pub fn init(vtable: *const VTable, ctx: *anyopaque) Spell {
    return .{ .vtable = vtable, .ctx = ctx };
}

pub fn checkText(self: *Spell, allocator: std.mem.Allocator, text: []const u8) ![]const TokenResult {
    try self.ensureConfusions();

    const tokens = try Tokenizer.wordsFromText(allocator, text, .{ .normalize = true });
    if (tokens.len == 0) return &.{};

    var order: std.ArrayList([]const u8) = .empty;
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    for (tokens) |w| {
        if (w.len == 0) continue;
        try order.append(allocator, w);
        _ = try unique.getOrPut(allocator, w);
    }
    if (order.items.len == 0) return &.{};

    var known: std.StringHashMapUnmanaged(i64) = .empty;
    {
        var words: std.ArrayList([]const u8) = .empty;
        var it = unique.keyIterator();
        while (it.next()) |k| try words.append(allocator, k.*);
        const rows = try self.vtable.lookup_words(self.ctx, allocator, words.items);
        for (rows) |row| try known.put(allocator, row.word, row.frequency);
    }

    var oov_words: std.ArrayList([]const u8) = .empty;
    var delete_keys: std.ArrayList([]const u8) = .empty;
    var key_seen: std.StringHashMapUnmanaged(void) = .empty;
    var keys_by_oov: std.StringHashMapUnmanaged([]const []const u8) = .empty;

    var uit = unique.keyIterator();
    while (uit.next()) |k| {
        const w = k.*;
        if (known.contains(w)) continue;
        try oov_words.append(allocator, w);

        const max_dist: u8 = if (countCodepoints(w) <= 6) 2 else 1;
        var local_keys: std.ArrayList([]const u8) = .empty;
        var local_seen: std.StringHashMapUnmanaged(void) = .empty;
        try emitDeletes(allocator, &local_seen, &local_keys, w, max_dist);
        try local_keys.append(allocator, w);

        for (local_keys.items) |dk| {
            const gop = try key_seen.getOrPut(allocator, dk);
            if (!gop.found_existing) try delete_keys.append(allocator, dk);
        }
        try keys_by_oov.put(allocator, w, try local_keys.toOwnedSlice(allocator));
    }

    var cand_by_key: std.StringHashMapUnmanaged([]const LexiconEntry) = .empty;
    if (delete_keys.items.len > 0) {
        const hits = try self.vtable.lookup_deletes(self.ctx, allocator, delete_keys.items);
        var staging: std.StringHashMapUnmanaged(std.ArrayList(LexiconEntry)) = .empty;
        for (hits) |h| {
            const gop = try staging.getOrPut(allocator, h.delete_key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .word = h.word, .frequency = h.frequency });
        }
        var sit = staging.iterator();
        while (sit.next()) |e| {
            try cand_by_key.put(allocator, e.key_ptr.*, try e.value_ptr.toOwnedSlice(allocator));
        }
    }

    var confuse_variants: std.ArrayList([]const u8) = .empty;
    var confuse_seen: std.StringHashMapUnmanaged(void) = .empty;
    var confuse_by_oov: std.StringHashMapUnmanaged([]const []const u8) = .empty;

    for (oov_words.items) |w| {
        var local: std.ArrayList([]const u8) = .empty;
        var local_seen: std.StringHashMapUnmanaged(void) = .empty;
        const depth: u8 = if (countCodepoints(w) <= 5) 2 else 1;
        try self.emitConfusionSubs(allocator, &local_seen, &local, w, depth);
        for (local.items) |v| {
            const gop = try confuse_seen.getOrPut(allocator, v);
            if (!gop.found_existing) try confuse_variants.append(allocator, v);
        }
        try confuse_by_oov.put(allocator, w, try local.toOwnedSlice(allocator));
    }

    var confuse_hits: std.StringHashMapUnmanaged(LexiconEntry) = .empty;
    if (confuse_variants.items.len > 0) {
        const rows = try self.vtable.lookup_words(self.ctx, allocator, confuse_variants.items);
        for (rows) |row| try confuse_hits.put(allocator, row.word, row);
    }

    var cand_by_oov: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(RankedCandidate)) = .empty;
    for (oov_words.items) |w| {
        var best: std.StringHashMapUnmanaged(RankedCandidate) = .empty;

        const keys = keys_by_oov.get(w) orelse &.{};
        for (keys) |dk| {
            const cands = cand_by_key.get(dk) orelse continue;
            for (cands) |c| {
                try considerCandidate(allocator, &best, &self.confusions, w, c.word, c.frequency);
            }
        }

        const variants = confuse_by_oov.get(w) orelse &.{};
        for (variants) |v| {
            const hit = confuse_hits.get(v) orelse continue;
            try considerCandidate(allocator, &best, &self.confusions, w, hit.word, hit.frequency);
        }

        try cand_by_oov.put(allocator, w, best);
    }

    var out: std.ArrayList(TokenResult) = .empty;
    for (order.items, 0..) |tok, i| {
        if (known.contains(tok)) {
            try out.append(allocator, .{ .token = tok, .known = true, .suggestions = &.{} });
            continue;
        }

        const base = cand_by_oov.getPtr(tok) orelse {
            try out.append(allocator, .{ .token = tok, .known = false, .suggestions = &.{} });
            continue;
        };

        var ranked = try cloneRanked(allocator, base.*);
        const prev2: []const u8 = if (i >= 2) order.items[i - 2] else "";
        const prev1: []const u8 = if (i >= 1) order.items[i - 1] else "";
        const next: []const u8 = if (i + 1 < order.items.len) order.items[i + 1] else "";
        try applyNgramContext(self, allocator, &ranked, prev2, prev1, next);

        try out.append(allocator, .{
            .token = tok,
            .known = false,
            .suggestions = try finishSuggestions(allocator, &ranked, 8),
        });
    }
    return try out.toOwnedSlice(allocator);
}

/// Ranked corrections for a single misspelled word, optionally boosted by
/// left/right n-gram context (`prev2 prev1 _ next`).
pub fn suggestWord(
    self: *Spell,
    allocator: std.mem.Allocator,
    word: []const u8,
    prev2: []const u8,
    prev1: []const u8,
    next: []const u8,
    limit: usize,
) ![]const Suggestion {
    if (word.len == 0) return &.{};
    try self.ensureConfusions();

    // Reuse checkText on a tiny synthetic phrase so SymSpell + confusions stay
    // in one path; context words that are empty are omitted.
    var buf: std.ArrayList(u8) = .empty;
    if (prev2.len > 0) {
        try buf.appendSlice(allocator, prev2);
        try buf.append(allocator, ' ');
    }
    if (prev1.len > 0) {
        try buf.appendSlice(allocator, prev1);
        try buf.append(allocator, ' ');
    }
    const target_index: usize = blk: {
        var n: usize = 0;
        if (prev2.len > 0) n += 1;
        if (prev1.len > 0) n += 1;
        break :blk n;
    };
    try buf.appendSlice(allocator, word);
    if (next.len > 0) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, next);
    }

    const results = try self.checkText(allocator, buf.items);
    if (target_index >= results.len) return &.{};
    const ranked = results[target_index].suggestions;
    if (ranked.len <= limit) return ranked;
    return ranked[0..limit];
}

pub fn prefixSuggest(self: *Spell, allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Suggestion {
    if (prefix.len == 0) return &.{};
    const rows = try self.vtable.prefix_suggest(self.ctx, allocator, prefix, limit);
    return try lexiconToSuggestions(allocator, rows);
}

pub fn nextWordSuggest(self: *Spell, allocator: std.mem.Allocator, previous_word: []const u8, limit: i64) ![]const Suggestion {
    if (previous_word.len == 0) return &.{};
    const rows = try self.vtable.next_word_suggest(self.ctx, allocator, previous_word, limit);
    return try lexiconToSuggestions(allocator, rows);
}

pub fn trigramNextWordSuggest(self: *Spell, allocator: std.mem.Allocator, w1: []const u8, w2: []const u8, limit: i64) ![]const Suggestion {
    if (w1.len == 0 or w2.len == 0) return &.{};
    const rows = try self.vtable.trigram_next_word_suggest(self.ctx, allocator, w1, w2, limit);
    return try lexiconToSuggestions(allocator, rows);
}

fn ensureConfusions(self: *Spell) !void {
    if (self.confusions.loaded) return;
    self.confusions.loaded = true;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();

    const rules = self.vtable.load_confusions(self.ctx, a) catch {
        arena.deinit();
        return;
    };

    var map: std.StringHashMapUnmanaged(std.ArrayList(ConfusionTarget)) = .empty;
    var edges: std.ArrayList(ConfusionEdge) = .empty;

    for (rules) |rule| {
        const milli: i64 = @intFromFloat(@round(rule.weight * 1000.0));
        const gop = map.getOrPut(a, rule.from_g) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(a, .{ .to_g = rule.to_g, .milli = milli }) catch continue;
        edges.append(a, .{ .from_g = rule.from_g, .to_g = rule.to_g, .milli = milli }) catch continue;
    }

    var final_map: std.StringHashMapUnmanaged([]const ConfusionTarget) = .empty;
    var mit = map.iterator();
    while (mit.next()) |e| {
        final_map.put(a, e.key_ptr.*, e.value_ptr.toOwnedSlice(a) catch continue) catch continue;
    }

    self.confusions.arena = arena;
    self.confusions.map = final_map;
    self.confusions.edges = edges.toOwnedSlice(a) catch &.{};
}

fn emitConfusionSubs(
    self: *Spell,
    allocator: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList([]const u8),
    current: []const u8,
    depth_left: u8,
) !void {
    if (depth_left == 0 or self.confusions.map.count() == 0) return;

    var i: usize = 0;
    while (i < current.len) {
        var mit = self.confusions.map.iterator();
        while (mit.next()) |e| {
            const from = e.key_ptr.*;
            if (!std.mem.startsWith(u8, current[i..], from)) continue;
            for (e.value_ptr.*) |to| {
                const variant = try concatReplace(allocator, current, i, from.len, to.to_g);
                const gop = try seen.getOrPut(allocator, variant);
                if (gop.found_existing) continue;
                gop.value_ptr.* = {};
                try out.append(allocator, variant);
                if (depth_left > 1) {
                    try self.emitConfusionSubs(allocator, seen, out, variant, depth_left - 1);
                }
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(current[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > current.len) break;
        i += len;
    }
}

const ConfusionTarget = struct {
    to_g: []const u8,
    milli: i64,
};

const ConfusionEdge = struct {
    from_g: []const u8,
    to_g: []const u8,
    milli: i64,
};

const ConfusionIndex = struct {
    loaded: bool = false,
    arena: ?std.heap.ArenaAllocator = null,
    map: std.StringHashMapUnmanaged([]const ConfusionTarget) = .empty,
    edges: []const ConfusionEdge = &.{},
};

const RankedCandidate = struct {
    frequency: i64,
    distance: usize,
    score: i64,
};

/// log2 boost weights — trigrams dominate left bigrams; right bigrams are a light tie-break.
const trigram_context_weight: i64 = 140_000;
const bigram_left_weight: i64 = 70_000;
const bigram_right_weight: i64 = 45_000;
const unigram_frequency_weight: i64 = 6_000;

fn cloneRanked(
    allocator: std.mem.Allocator,
    src: std.StringHashMapUnmanaged(RankedCandidate),
) !std.StringHashMapUnmanaged(RankedCandidate) {
    var dst: std.StringHashMapUnmanaged(RankedCandidate) = .empty;
    var it = src.iterator();
    while (it.next()) |e| {
        try dst.put(allocator, e.key_ptr.*, e.value_ptr.*);
    }
    return dst;
}

fn ngramScoreBoost(freq: i64, weight: i64) i64 {
    if (freq <= 0) return 0;
    const f: u64 = @intCast(freq);
    return @as(i64, @intCast(std.math.log2_int(u64, f + 1))) * weight;
}

fn applyNgramContext(
    self: *Spell,
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(RankedCandidate),
    prev2: []const u8,
    prev1: []const u8,
    next: []const u8,
) !void {
    if (best.count() == 0) return;

    var cands: std.ArrayList([]const u8) = .empty;
    var it = best.keyIterator();
    while (it.next()) |k| try cands.append(allocator, k.*);
    if (cands.items.len == 0) return;

    if (prev1.len > 0) {
        const hits = try self.vtable.lookup_bigrams(self.ctx, allocator, prev1, cands.items);
        for (hits) |h| {
            if (best.getPtr(h.word)) |rc| {
                rc.score += ngramScoreBoost(h.frequency, bigram_left_weight);
            }
        }
    }

    if (prev2.len > 0 and prev1.len > 0) {
        const hits = try self.vtable.lookup_trigrams(self.ctx, allocator, prev2, prev1, cands.items);
        for (hits) |h| {
            if (best.getPtr(h.word)) |rc| {
                rc.score += ngramScoreBoost(h.frequency, trigram_context_weight);
            }
        }
    }

    if (next.len > 0) {
        const hits = try self.vtable.lookup_bigrams_right(self.ctx, allocator, cands.items, next);
        for (hits) |h| {
            if (best.getPtr(h.word)) |rc| {
                rc.score += ngramScoreBoost(h.frequency, bigram_right_weight);
            }
        }
    }
}

fn considerCandidate(
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(RankedCandidate),
    confusions: *const ConfusionIndex,
    typed: []const u8,
    word: []const u8,
    frequency: i64,
) !void {
    const milli = weightedEditCostMilli(confusions.edges, typed, word);
    const max_milli: i64 = 2_500;
    if (milli > max_milli) return;
    const hops: usize = @intCast(@divTrunc(milli + 999, 1000));
    const score = rankScore(typed, word, milli, frequency);
    const gop = try best.getOrPut(allocator, word);
    if (!gop.found_existing or score > gop.value_ptr.score) {
        gop.value_ptr.* = .{ .frequency = frequency, .distance = hops, .score = score };
    }
}

fn finishSuggestions(
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(RankedCandidate),
    limit: usize,
) ![]const Suggestion {
    var list: std.ArrayList(Suggestion) = .empty;
    var it = best.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, .{
            .word = entry.key_ptr.*,
            .frequency = entry.value_ptr.frequency,
            .distance = entry.value_ptr.distance,
            .score = entry.value_ptr.score,
        });
    }
    std.mem.sort(Suggestion, list.items, {}, struct {
        fn less(_: void, a: Suggestion, b: Suggestion) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.frequency > b.frequency;
        }
    }.less);
    if (list.items.len > limit) list.shrinkRetainingCapacity(limit);
    return try list.toOwnedSlice(allocator);
}

fn lexiconToSuggestions(allocator: std.mem.Allocator, rows: []const LexiconEntry) ![]const Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    for (rows) |row| {
        try out.append(allocator, .{ .word = row.word, .frequency = row.frequency });
    }
    return try out.toOwnedSlice(allocator);
}

fn rankScore(typed: []const u8, candidate: []const u8, milli: i64, freq: i64) i64 {
    var typed_cps: [64]u21 = undefined;
    var cand_cps: [64]u21 = undefined;
    const tn = fillCodepoints(typed, &typed_cps) orelse return std.math.minInt(i64);
    const cn = fillCodepoints(candidate, &cand_cps) orelse return std.math.minInt(i64);
    const len_diff: i64 = @intCast(if (tn > cn) tn - cn else cn - tn);
    const lcs = longestCommonSubseq(typed_cps[0..tn], cand_cps[0..cn]);

    var score: i64 = 0;
    score -= milli * 1_000;
    score += @as(i64, @intCast(lcs)) * 100_000;
    if (tn > 0 and cn > 0 and typed_cps[0] == cand_cps[0]) score += 80_000;
    score -= len_diff * 20_000;
    const f: u64 = if (freq > 0) @intCast(freq) else 1;
    score += @as(i64, @intCast(std.math.log2_int(u64, f))) * unigram_frequency_weight;
    return score;
}

fn longestCommonSubseq(a: []const u21, b: []const u21) usize {
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    @memset(&prev, 0);
    @memset(&cur, 0);
    for (a) |ca| {
        @memset(cur[0 .. b.len + 1], 0);
        for (b, 0..) |cb, j| {
            if (ca == cb) {
                cur[j + 1] = prev[j] + 1;
            } else {
                cur[j + 1] = @max(prev[j + 1], cur[j]);
            }
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

// --- SymSpell delete generation ---------------------------------------------------

fn emitDeletes(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList([]const u8),
    current: []const u8,
    distance_left: u8,
) !void {
    if (distance_left == 0) return;

    var cps: std.ArrayList([]const u8) = .empty;
    try utf8CodepointSlices(allocator, current, &cps);
    if (cps.items.len == 0) return;

    var i: usize = 0;
    while (i < cps.items.len) : (i += 1) {
        const deleted = try concatCodepointsExcept(allocator, cps.items, i);
        const gop = try seen.getOrPut(allocator, deleted);
        if (gop.found_existing) continue;
        gop.value_ptr.* = {};
        try out.append(allocator, deleted);
        try emitDeletes(allocator, seen, out, deleted, distance_left - 1);
    }
}

fn weightedEditCostMilli(edges: []const ConfusionEdge, a: []const u8, b: []const u8) i64 {
    if (std.mem.eql(u8, a, b)) return 0;
    if (singleConfusionCost(edges, a, b)) |c| return c;
    return weightedCodepointEditMilli(edges, a, b);
}

fn singleConfusionCost(edges: []const ConfusionEdge, typed: []const u8, cand: []const u8) ?i64 {
    var best: ?i64 = null;
    var i: usize = 0;
    while (i < typed.len) {
        for (edges) |edge| {
            if (!std.mem.startsWith(u8, typed[i..], edge.from_g)) continue;
            const after = i + edge.from_g.len;
            const rebuilt_len = i + edge.to_g.len + (typed.len - after);
            if (rebuilt_len != cand.len) continue;
            if (!std.mem.eql(u8, typed[0..i], cand[0..i])) continue;
            if (!std.mem.eql(u8, edge.to_g, cand[i .. i + edge.to_g.len])) continue;
            if (!std.mem.eql(u8, typed[after..], cand[i + edge.to_g.len ..])) continue;
            if (best == null or edge.milli < best.?) best = edge.milli;
        }
        const len = std.unicode.utf8ByteSequenceLength(typed[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > typed.len) break;
        i += len;
    }
    return best;
}

fn substitutionMilli(edges: []const ConfusionEdge, from_cp: u21, to_cp: u21) i64 {
    if (from_cp == to_cp) return 0;
    var from_buf: [4]u8 = undefined;
    var to_buf: [4]u8 = undefined;
    const from_len = std.unicode.utf8Encode(from_cp, &from_buf) catch return 1_000;
    const to_len = std.unicode.utf8Encode(to_cp, &to_buf) catch return 1_000;
    const from_s = from_buf[0..from_len];
    const to_s = to_buf[0..to_len];
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.from_g, from_s) and std.mem.eql(u8, edge.to_g, to_s)) {
            return edge.milli;
        }
    }
    return 1_000;
}

fn weightedCodepointEditMilli(edges: []const ConfusionEdge, a: []const u8, b: []const u8) i64 {
    const max_milli: i64 = 2_500;
    var a_cps: [64]u21 = undefined;
    var b_cps: [64]u21 = undefined;
    const an = fillCodepoints(a, &a_cps) orelse return max_milli + 1;
    const bn = fillCodepoints(b, &b_cps) orelse return max_milli + 1;
    if (@abs(@as(i32, @intCast(an)) - @as(i32, @intCast(bn))) > 2) return max_milli + 1;

    var prev: [65]i64 = undefined;
    var cur: [65]i64 = undefined;
    var i: usize = 0;
    while (i <= bn) : (i += 1) prev[i] = @as(i64, @intCast(i)) * 1_000;

    i = 0;
    while (i < an) : (i += 1) {
        cur[0] = @as(i64, @intCast(i + 1)) * 1_000;
        var row_min: i64 = cur[0];
        var j: usize = 0;
        while (j < bn) : (j += 1) {
            const cost = substitutionMilli(edges, a_cps[i], b_cps[j]);
            const del = prev[j + 1] + 1_000;
            const ins = cur[j] + 1_000;
            const sub = prev[j] + cost;
            var best = @min(del, @min(ins, sub));
            if (i > 0 and j > 0 and a_cps[i] == b_cps[j - 1] and a_cps[i - 1] == b_cps[j]) {
                best = @min(best, prev[j - 1] + 1_000);
            }
            cur[j + 1] = best;
            row_min = @min(row_min, best);
        }
        if (row_min > max_milli) return max_milli + 1;
        @memcpy(prev[0 .. bn + 1], cur[0 .. bn + 1]);
    }
    return prev[bn];
}

fn concatReplace(allocator: std.mem.Allocator, s: []const u8, at: usize, from_len: usize, to_g: []const u8) ![]const u8 {
    const after = at + from_len;
    const buf = try allocator.alloc(u8, at + to_g.len + (s.len - after));
    @memcpy(buf[0..at], s[0..at]);
    @memcpy(buf[at .. at + to_g.len], to_g);
    @memcpy(buf[at + to_g.len ..], s[after..]);
    return buf;
}

fn utf8CodepointSlices(allocator: std.mem.Allocator, s: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        try out.append(allocator, s[i .. i + len]);
        i += len;
    }
}

fn concatCodepointsExcept(allocator: std.mem.Allocator, cps: []const []const u8, skip: usize) ![]const u8 {
    var total: usize = 0;
    for (cps, 0..) |cp, i| {
        if (i != skip) total += cp.len;
    }
    const buf = try allocator.alloc(u8, total);
    var o: usize = 0;
    for (cps, 0..) |cp, i| {
        if (i == skip) continue;
        @memcpy(buf[o .. o + cp.len], cp);
        o += cp.len;
    }
    return buf;
}

fn countCodepoints(s: []const u8) usize {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    var n: usize = 0;
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

fn fillCodepoints(s: []const u8, out: *[64]u21) ?usize {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (n >= out.len) return null;
        out[n] = cp;
        n += 1;
    }
    return n;
}
