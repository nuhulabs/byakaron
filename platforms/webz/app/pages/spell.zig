const std = @import("std");
const zx = @import("zx");

pub const Suggestion = struct {
    word: []const u8,
    frequency: i64,
    distance: usize = 0,
};

pub const TokenResult = struct {
    token: []const u8,
    known: bool,
    suggestions: []const Suggestion,
};

const DictRow = struct {
    id: i64,
    word: []const u8,
    frequency: i64,
};

const CandidateRow = struct {
    word: []const u8,
    frequency: i64,
};

const Ranked = struct {
    frequency: i64,
    distance: usize,
};

/// All allocations use the request arena — do not free the returned slices.
pub fn checkText(allocator: std.mem.Allocator, text: []const u8) ![]const TokenResult {
    var tokens: std.ArrayList(TokenResult) = .empty;

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) {
        const at_end = i == text.len;
        const is_space = !at_end and isTokenSep(text[i]);
        if (at_end or is_space) {
            if (i > start) {
                const raw = text[start..i];
                if (isCheckableWord(raw)) {
                    try tokens.append(allocator, try checkWord(allocator, raw));
                }
            }
            if (at_end) break;
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }

    return try tokens.toOwnedSlice(allocator);
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

fn checkWord(allocator: std.mem.Allocator, word: []const u8) !TokenResult {
    if (try lookupExact(allocator, word)) |_| {
        return .{
            .token = word,
            .known = true,
            .suggestions = &.{},
        };
    }

    return .{
        .token = word,
        .known = false,
        .suggestions = try suggest(allocator, word, 8),
    };
}

fn lookupExact(allocator: std.mem.Allocator, word: []const u8) !?DictRow {
    return try zx.db.row(allocator, DictRow,
        \\SELECT id, word, frequency FROM dictionary WHERE word = ?1 LIMIT 1
    , .{word});
}

fn suggest(allocator: std.mem.Allocator, word: []const u8, limit: usize) ![]const Suggestion {
    var delete_keys: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try emitDeletes(allocator, &seen, &delete_keys, word, 2);

    var best: std.StringHashMapUnmanaged(Ranked) = .empty;

    try considerDeleteKey(allocator, &best, word, word);
    for (delete_keys.items) |key| {
        try considerDeleteKey(allocator, &best, word, key);
    }

    var list: std.ArrayList(Suggestion) = .empty;
    var it = best.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, .{
            .word = entry.key_ptr.*,
            .frequency = entry.value_ptr.frequency,
            .distance = entry.value_ptr.distance,
        });
    }

    std.mem.sort(Suggestion, list.items, {}, struct {
        fn less(_: void, a: Suggestion, b: Suggestion) bool {
            if (a.distance != b.distance) return a.distance < b.distance;
            return a.frequency > b.frequency;
        }
    }.less);

    if (list.items.len > limit) list.shrinkRetainingCapacity(limit);
    return try list.toOwnedSlice(allocator);
}

fn considerDeleteKey(
    allocator: std.mem.Allocator,
    best: *std.StringHashMapUnmanaged(Ranked),
    typed: []const u8,
    key: []const u8,
) !void {
    const rows = try zx.db.rows(allocator, CandidateRow,
        \\SELECT dict.word AS word, dict.frequency AS frequency
        \\FROM deletes d
        \\JOIN dictionary dict ON dict.id = d.word_id
        \\WHERE d.delete_key = ?1
        \\ORDER BY dict.frequency DESC
        \\LIMIT 40
    , .{key});

    for (rows) |row| {
        const dist = codepointEditDistance(typed, row.word);
        if (dist > 2) continue;
        const gop = try best.getOrPut(allocator, row.word);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .frequency = row.frequency, .distance = dist };
        } else {
            if (dist < gop.value_ptr.distance or (dist == gop.value_ptr.distance and row.frequency > gop.value_ptr.frequency)) {
                gop.value_ptr.* = .{ .frequency = row.frequency, .distance = dist };
            }
        }
    }
}

fn toSuggestions(allocator: std.mem.Allocator, rows: []const CandidateRow) ![]const Suggestion {
    var out: std.ArrayList(Suggestion) = .empty;
    for (rows) |row| {
        try out.append(allocator, .{
            .word = row.word,
            .frequency = row.frequency,
        });
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

fn isTokenSep(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ';', ':', '?', '!', '"', '\'', '(', ')', '[', ']', '{', '}', '/', '\\' => true,
        else => false,
    };
}

fn isCheckableWord(s: []const u8) bool {
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    var bangla = false;
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x0980 and cp <= 0x09FF) bangla = true;
    }
    return bangla;
}

/// Damerau–Levenshtein on Unicode codepoints, capped early above `max`.
fn codepointEditDistance(a: []const u8, b: []const u8) usize {
    const max_dist: usize = 2;
    var a_cps: [64]u21 = undefined;
    var b_cps: [64]u21 = undefined;
    const an = fillCodepoints(a, &a_cps) orelse return max_dist + 1;
    const bn = fillCodepoints(b, &b_cps) orelse return max_dist + 1;
    if (@abs(@as(i32, @intCast(an)) - @as(i32, @intCast(bn))) > max_dist) return max_dist + 1;

    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    var i: usize = 0;
    while (i <= bn) : (i += 1) prev[i] = i;

    i = 0;
    while (i < an) : (i += 1) {
        cur[0] = i + 1;
        var row_min: usize = cur[0];
        var j: usize = 0;
        while (j < bn) : (j += 1) {
            const cost: usize = if (a_cps[i] == b_cps[j]) 0 else 1;
            const del = prev[j + 1] + 1;
            const ins = cur[j] + 1;
            const sub = prev[j] + cost;
            var best = @min(del, @min(ins, sub));
            if (i > 0 and j > 0 and a_cps[i] == b_cps[j - 1] and a_cps[i - 1] == b_cps[j]) {
                best = @min(best, prev[j - 1] + 1); // transpose uses prev-prev conceptually; approx with prev
            }
            cur[j + 1] = best;
            row_min = @min(row_min, best);
        }
        if (row_min > max_dist) return max_dist + 1;
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
