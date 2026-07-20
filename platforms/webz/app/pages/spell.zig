const std = @import("std");
const zx = @import("zx");
const Tokenizer = @import("tokenization").Tokenizer;

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

const CandidateRow = struct {
    word: []const u8,
    frequency: i64,
};

const DeleteHit = struct {
    delete_key: []const u8,
    word: []const u8,
    frequency: i64,
};

const ConfusionRow = struct {
    from_g: []const u8,
    to_g: []const u8,
    weight: f64,
};

const ConfTo = struct {
    to_g: []const u8,
    /// Substitution cost in millunits (weight * 1000). Lower = more likely.
    milli: i64,
};

const Ranked = struct {
    frequency: i64,
    distance: usize,
    score: i64,
};

/// Process-lifetime confusion table (tiny; safe to keep in RAM).
var conf_loaded: bool = false;
var conf_arena_state: ?std.heap.ArenaAllocator = null;
var conf_map: std.StringHashMapUnmanaged([]const ConfTo) = .empty;
/// Flat edges for single-codepoint weighted Levenshtein (utf8 from → ConfTo list).
var conf_edges: []const ConfusionEdge = &.{};

const ConfusionEdge = struct {
    from_g: []const u8,
    to_g: []const u8,
    milli: i64,
};

fn ensureConfusions() void {
    if (conf_loaded) return;
    conf_loaded = true;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();

    const rows = zx.db.rows(a, ConfusionRow,
        \\SELECT from_g, to_g, weight FROM confusions
    , .{}) catch {
        arena.deinit();
        return;
    };

    var map: std.StringHashMapUnmanaged(std.ArrayList(ConfTo)) = .empty;
    var edges: std.ArrayList(ConfusionEdge) = .empty;

    for (rows) |row| {
        const milli: i64 = @intFromFloat(@round(row.weight * 1000.0));
        const from = row.from_g;
        const to = row.to_g;
        const gop = map.getOrPut(a, from) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(a, .{ .to_g = to, .milli = milli }) catch continue;
        edges.append(a, .{ .from_g = from, .to_g = to, .milli = milli }) catch continue;
    }

    var final_map: std.StringHashMapUnmanaged([]const ConfTo) = .empty;
    var mit = map.iterator();
    while (mit.next()) |e| {
        final_map.put(a, e.key_ptr.*, e.value_ptr.toOwnedSlice(a) catch continue) catch continue;
    }

    conf_arena_state = arena;
    conf_map = final_map;
    conf_edges = edges.toOwnedSlice(a) catch &.{};
}

/// Spell-check a paragraph with **batched** SQLite access:
/// 1) one `dictionary WHERE word IN (...)` for all unique tokens
/// 2) chunked `deletes WHERE delete_key IN (...)` for SymSpell keys of all OOVs
/// 3) one `dictionary WHERE word IN (...)` for confusion substitutions of OOVs
///
/// Note: ziex does **not** reopen the DB per request (connection is process-lifetime),
/// but each `zx.db.rows` **re-prepares** SQL — so fewer queries ≫ fewer prepares.
pub fn checkText(allocator: std.mem.Allocator, text: []const u8) ![]const TokenResult {
    ensureConfusions();

    // Shared Bangla tokenizer (nukta-normalized), same path as packages/data.
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

    // --- Pass 1: unique words that exist in the lexicon (one query) ---
    var known: std.StringHashMapUnmanaged(i64) = .empty;
    {
        var words: std.ArrayList([]const u8) = .empty;
        var it = unique.keyIterator();
        while (it.next()) |k| try words.append(allocator, k.*);
        const rows = try queryWordsIn(allocator, words.items);
        for (rows) |row| {
            try known.put(allocator, row.word, row.frequency);
        }
    }

    // --- Pass 2: SymSpell deletes for unique OOVs (chunked query) ---
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

    var cand_by_key: std.StringHashMapUnmanaged([]const CandidateRow) = .empty;
    if (delete_keys.items.len > 0) {
        const hits = try queryDeletesIn(allocator, delete_keys.items);
        var staging: std.StringHashMapUnmanaged(std.ArrayList(CandidateRow)) = .empty;
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

    // --- Pass 3: confusion expansions for OOVs (one batched dictionary IN) ---
    var confuse_variants: std.ArrayList([]const u8) = .empty;
    var confuse_seen: std.StringHashMapUnmanaged(void) = .empty;
    var confuse_by_oov: std.StringHashMapUnmanaged([]const []const u8) = .empty;

    for (oov_words.items) |w| {
        var local: std.ArrayList([]const u8) = .empty;
        var local_seen: std.StringHashMapUnmanaged(void) = .empty;
        const depth: u8 = if (countCodepoints(w) <= 5) 2 else 1;
        try emitConfusionSubs(allocator, &local_seen, &local, w, depth);
        for (local.items) |v| {
            const gop = try confuse_seen.getOrPut(allocator, v);
            if (!gop.found_existing) try confuse_variants.append(allocator, v);
        }
        try confuse_by_oov.put(allocator, w, try local.toOwnedSlice(allocator));
    }

    var confuse_hits: std.StringHashMapUnmanaged(CandidateRow) = .empty;
    if (confuse_variants.items.len > 0) {
        const rows = try queryWordsIn(allocator, confuse_variants.items);
        for (rows) |row| {
            try confuse_hits.put(allocator, row.word, row);
        }
    }

    var suggest_by_word: std.StringHashMapUnmanaged([]const Suggestion) = .empty;
    for (oov_words.items) |w| {
        var best: std.StringHashMapUnmanaged(Ranked) = .empty;

        // SymSpell delete candidates
        const keys = keys_by_oov.get(w) orelse &.{};
        for (keys) |dk| {
            const cands = cand_by_key.get(dk) orelse continue;
            for (cands) |c| {
                try considerCandidate(allocator, &best, w, c.word, c.frequency);
            }
        }

        // Confusion substitution candidates
        const variants = confuse_by_oov.get(w) orelse &.{};
        for (variants) |v| {
            const hit = confuse_hits.get(v) orelse continue;
            try considerCandidate(allocator, &best, w, hit.word, hit.frequency);
        }

        try suggest_by_word.put(allocator, w, try finishSuggestions(allocator, &best, 8));
    }

    // Emit one result per occurrence (same order as input tokens).
    var out: std.ArrayList(TokenResult) = .empty;
    for (order.items) |tok| {
        if (known.contains(tok)) {
            try out.append(allocator, .{ .token = tok, .known = true, .suggestions = &.{} });
        } else {
            try out.append(allocator, .{
                .token = tok,
                .known = false,
                .suggestions = suggest_by_word.get(tok) orelse &.{},
            });
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn considerCandidate(
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(Ranked),
    typed: []const u8,
    word: []const u8,
    frequency: i64,
) !void {
    const milli = weightedEditCostMilli(typed, word);
    const max_milli: i64 = 2_500;
    if (milli > max_milli) return;
    const hops: usize = @intCast(@divTrunc(milli + 999, 1000));
    const score = rankScore(typed, word, milli, frequency);
    const gop = try best.getOrPut(allocator, word);
    if (!gop.found_existing or score > gop.value_ptr.score) {
        gop.value_ptr.* = .{ .frequency = frequency, .distance = hops, .score = score };
    }
}

pub fn prefixSuggest(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Suggestion {
    if (prefix.len == 0) return &.{};
    const like = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    const rows = try zx.db.rows(allocator, CandidateRow,
        \\SELECT word, frequency FROM dictionary
        \\WHERE word LIKE ?1
        \\ORDER BY frequency DESC
        \\LIMIT ?2
    , .{ like, limit });
    return try toSuggestions(allocator, rows);
}

pub fn nextWordSuggest(allocator: std.mem.Allocator, prev: []const u8, limit: i64) ![]const Suggestion {
    if (prev.len == 0) return &.{};
    const rows = try zx.db.rows(allocator, CandidateRow,
        \\SELECT d2.word AS word, b.frequency AS frequency
        \\FROM dictionary d1
        \\JOIN bigrams b ON b.w1_id = d1.id
        \\JOIN dictionary d2 ON d2.id = b.w2_id
        \\WHERE d1.word = ?1
        \\ORDER BY b.frequency DESC
        \\LIMIT ?2
    , .{ prev, limit });
    return try toSuggestions(allocator, rows);
}

/// `WHERE word IN ('a','b',...)` — literals avoid ziex's comptime-only bind tuples.
fn queryWordsIn(allocator: std.mem.Allocator, words: []const []const u8) ![]const CandidateRow {
    if (words.len == 0) return &.{};

    const chunk_size = 120;
    var out: std.ArrayList(CandidateRow) = .empty;
    var offset: usize = 0;
    while (offset < words.len) {
        const end = @min(offset + chunk_size, words.len);
        const chunk = words[offset..end];
        offset = end;

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(allocator, "SELECT word, frequency FROM dictionary WHERE word IN (");
        for (chunk, 0..) |w, i| {
            if (i > 0) try sql.append(allocator, ',');
            try appendSqlString(allocator, &sql, w);
        }
        try sql.appendSlice(allocator, ")");
        const rows = try zx.db.rows(allocator, CandidateRow, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryDeletesIn(allocator: std.mem.Allocator, keys: []const []const u8) ![]const DeleteHit {
    if (keys.len == 0) return &.{};

    // Chunk to keep SQL text and SQLite planner happy on huge paragraphs.
    const chunk_size = 80;
    var out: std.ArrayList(DeleteHit) = .empty;
    var offset: usize = 0;
    while (offset < keys.len) {
        const end = @min(offset + chunk_size, keys.len);
        const chunk = keys[offset..end];
        offset = end;

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(allocator,
            \\SELECT d.delete_key AS delete_key, dict.word AS word, dict.frequency AS frequency
            \\FROM deletes d
            \\JOIN dictionary dict ON dict.id = d.word_id
            \\WHERE d.delete_key IN (
        );
        for (chunk, 0..) |k, i| {
            if (i > 0) try sql.append(allocator, ',');
            try appendSqlString(allocator, &sql, k);
        }
        try sql.appendSlice(allocator, ") ORDER BY dict.frequency DESC");

        const rows = try zx.db.rows(allocator, DeleteHit, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendSqlString(allocator: std.mem.Allocator, sql: *std.ArrayList(u8), s: []const u8) !void {
    try sql.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try sql.appendSlice(allocator, "''");
        } else {
            try sql.append(allocator, c);
        }
    }
    try sql.append(allocator, '\'');
}

fn finishSuggestions(
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(Ranked),
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

fn rankScore(typed: []const u8, candidate: []const u8, milli: i64, freq: i64) i64 {
    var typed_cps: [64]u21 = undefined;
    var cand_cps: [64]u21 = undefined;
    const tn = fillCodepoints(typed, &typed_cps) orelse return std.math.minInt(i64);
    const cn = fillCodepoints(candidate, &cand_cps) orelse return std.math.minInt(i64);
    const len_diff: i64 = @intCast(if (tn > cn) tn - cn else cn - tn);
    const lcs = longestCommonSubseq(typed_cps[0..tn], cand_cps[0..cn]);

    var score: i64 = 0;
    // milli already encodes lookalike preference (e.g. 250 vs 1000).
    score -= milli * 1_000;
    score += @as(i64, @intCast(lcs)) * 100_000;
    if (tn > 0 and cn > 0 and typed_cps[0] == cand_cps[0]) score += 80_000;
    score -= len_diff * 20_000;
    const f: u64 = if (freq > 0) @intCast(freq) else 1;
    score += @as(i64, @intCast(std.math.log2_int(u64, f)));
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

fn toSuggestions(allocator: std.mem.Allocator, rows: []const CandidateRow) ![]const Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    for (rows) |row| {
        try out.append(allocator, .{ .word = row.word, .frequency = row.frequency });
    }
    return try out.toOwnedSlice(allocator);
}

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

/// Depth-1 (or 2) Hunspell-style REP substitutions using the loaded confusion map.
fn emitConfusionSubs(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList([]const u8),
    current: []const u8,
    depth_left: u8,
) !void {
    if (depth_left == 0 or conf_map.count() == 0) return;

    var i: usize = 0;
    while (i < current.len) {
        var mit = conf_map.iterator();
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
                    try emitConfusionSubs(allocator, seen, out, variant, depth_left - 1);
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

fn concatReplace(
    allocator: std.mem.Allocator,
    s: []const u8,
    at: usize,
    from_len: usize,
    to_g: []const u8,
) ![]const u8 {
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

/// Prefer a single REP substitution path when it fully explains the edit;
/// otherwise weighted Levenshtein (known lookalikes ≪ random subs).
fn weightedEditCostMilli(a: []const u8, b: []const u8) i64 {
    if (std.mem.eql(u8, a, b)) return 0;
    if (singleConfusionCost(a, b)) |c| return c;
    return weightedCodepointEditMilli(a, b);
}

fn singleConfusionCost(typed: []const u8, cand: []const u8) ?i64 {
    var best: ?i64 = null;
    var i: usize = 0;
    while (i < typed.len) {
        for (conf_edges) |edge| {
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

fn substitutionMilli(from_cp: u21, to_cp: u21) i64 {
    if (from_cp == to_cp) return 0;
    var from_buf: [4]u8 = undefined;
    var to_buf: [4]u8 = undefined;
    const from_len = std.unicode.utf8Encode(from_cp, &from_buf) catch return 1_000;
    const to_len = std.unicode.utf8Encode(to_cp, &to_buf) catch return 1_000;
    const from_s = from_buf[0..from_len];
    const to_s = to_buf[0..to_len];
    for (conf_edges) |edge| {
        if (std.mem.eql(u8, edge.from_g, from_s) and std.mem.eql(u8, edge.to_g, to_s)) {
            return edge.milli;
        }
    }
    return 1_000;
}

fn weightedCodepointEditMilli(a: []const u8, b: []const u8) i64 {
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
            const cost = substitutionMilli(a_cps[i], b_cps[j]);
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
