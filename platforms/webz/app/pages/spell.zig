const std = @import("std");
const zx = @import("zx");
const Spell = @import("spell");

pub const Suggestion = Spell.Suggestion;
pub const TokenResult = Spell.TokenResult;

var engine: ?Spell = null;

fn spellEngine() *Spell {
    if (engine == null) {
        engine = Spell.init(&db_vtable, undefined);
    }
    return &engine.?;
}

pub fn checkText(allocator: std.mem.Allocator, text: []const u8) ![]const TokenResult {
    return try spellEngine().checkText(allocator, text);
}

pub fn prefixSuggest(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Suggestion {
    return try spellEngine().prefixSuggest(allocator, prefix, limit);
}

pub fn nextWordSuggest(allocator: std.mem.Allocator, prev: []const u8, limit: i64) ![]const Suggestion {
    return try spellEngine().nextWordSuggest(allocator, prev, limit);
}

const db_vtable = Spell.VTable{
    .lookup_words = lookupWords,
    .lookup_deletes = lookupDeletes,
    .prefix_suggest = prefixSuggestDb,
    .next_word_suggest = nextWordSuggestDb,
    .lookup_bigrams = lookupBigrams,
    .lookup_bigrams_right = lookupBigramsRight,
    .lookup_trigrams = lookupTrigrams,
    .load_confusions = loadConfusions,
};

const ConfusionRow = struct {
    from_g: []const u8,
    to_g: []const u8,
    weight: f64,
};

fn lookupWords(ctx: *anyopaque, allocator: std.mem.Allocator, words: []const []const u8) ![]const Spell.LexiconEntry {
    _ = ctx;
    return try queryWordsIn(allocator, words);
}

fn lookupDeletes(ctx: *anyopaque, allocator: std.mem.Allocator, delete_keys: []const []const u8) ![]const Spell.DeleteLookupHit {
    _ = ctx;
    return try queryDeletesIn(allocator, delete_keys);
}

fn prefixSuggestDb(ctx: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Spell.LexiconEntry {
    _ = ctx;
    const like = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    return try zx.db.rows(allocator, Spell.LexiconEntry,
        \\SELECT word, frequency FROM dictionary
        \\WHERE word LIKE ?1
        \\ORDER BY frequency DESC
        \\LIMIT ?2
    , .{ like, limit });
}

fn nextWordSuggestDb(ctx: *anyopaque, allocator: std.mem.Allocator, previous_word: []const u8, limit: i64) ![]const Spell.LexiconEntry {
    _ = ctx;
    return try zx.db.rows(allocator, Spell.LexiconEntry,
        \\SELECT d2.word AS word, b.frequency AS frequency
        \\FROM dictionary d1
        \\JOIN bigrams b ON b.w1_id = d1.id
        \\JOIN dictionary d2 ON d2.id = b.w2_id
        \\WHERE d1.word = ?1
        \\ORDER BY b.frequency DESC
        \\LIMIT ?2
    , .{ previous_word, limit });
}

fn lookupBigrams(ctx: *anyopaque, allocator: std.mem.Allocator, left: []const u8, rights: []const []const u8) ![]const Spell.LexiconEntry {
    _ = ctx;
    if (left.len == 0 or rights.len == 0) return &.{};
    return try queryBigramsLeft(allocator, left, rights);
}

fn lookupBigramsRight(ctx: *anyopaque, allocator: std.mem.Allocator, lefts: []const []const u8, right: []const u8) ![]const Spell.LexiconEntry {
    _ = ctx;
    if (right.len == 0 or lefts.len == 0) return &.{};
    return try queryBigramsRight(allocator, lefts, right);
}

fn lookupTrigrams(ctx: *anyopaque, allocator: std.mem.Allocator, w1: []const u8, w2: []const u8, w3s: []const []const u8) ![]const Spell.LexiconEntry {
    _ = ctx;
    if (w1.len == 0 or w2.len == 0 or w3s.len == 0) return &.{};
    return try queryTrigrams(allocator, w1, w2, w3s);
}

fn loadConfusions(ctx: *anyopaque, allocator: std.mem.Allocator) ![]const Spell.ConfusionRule {
    _ = ctx;
    const rows = try zx.db.rows(allocator, ConfusionRow,
        \\SELECT from_g, to_g, weight FROM confusions
    , .{});
    var out: std.ArrayList(Spell.ConfusionRule) = .empty;
    for (rows) |row| {
        try out.append(allocator, .{
            .from_g = row.from_g,
            .to_g = row.to_g,
            .weight = row.weight,
        });
    }
    return try out.toOwnedSlice(allocator);
}

/// `WHERE word IN ('a','b',...)` — literals avoid ziex's comptime-only bind tuples.
fn queryWordsIn(allocator: std.mem.Allocator, words: []const []const u8) ![]const Spell.LexiconEntry {
    if (words.len == 0) return &.{};

    const chunk_size = 120;
    var out: std.ArrayList(Spell.LexiconEntry) = .empty;
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
        const rows = try zx.db.rows(allocator, Spell.LexiconEntry, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryDeletesIn(allocator: std.mem.Allocator, keys: []const []const u8) ![]const Spell.DeleteLookupHit {
    if (keys.len == 0) return &.{};

    const chunk_size = 80;
    var out: std.ArrayList(Spell.DeleteLookupHit) = .empty;
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

        const rows = try zx.db.rows(allocator, Spell.DeleteLookupHit, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryBigramsLeft(allocator: std.mem.Allocator, left: []const u8, rights: []const []const u8) ![]const Spell.LexiconEntry {
    const chunk_size = 80;
    var out: std.ArrayList(Spell.LexiconEntry) = .empty;
    var offset: usize = 0;
    while (offset < rights.len) {
        const end = @min(offset + chunk_size, rights.len);
        const chunk = rights[offset..end];
        offset = end;

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(allocator,
            \\SELECT d2.word AS word, b.frequency AS frequency
            \\FROM dictionary d1
            \\JOIN bigrams b ON b.w1_id = d1.id
            \\JOIN dictionary d2 ON d2.id = b.w2_id
            \\WHERE d1.word =
        );
        try appendSqlString(allocator, &sql, left);
        try sql.appendSlice(allocator, " AND d2.word IN (");
        for (chunk, 0..) |w, i| {
            if (i > 0) try sql.append(allocator, ',');
            try appendSqlString(allocator, &sql, w);
        }
        try sql.append(allocator, ')');

        const rows = try zx.db.rows(allocator, Spell.LexiconEntry, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryBigramsRight(allocator: std.mem.Allocator, lefts: []const []const u8, right: []const u8) ![]const Spell.LexiconEntry {
    const chunk_size = 80;
    var out: std.ArrayList(Spell.LexiconEntry) = .empty;
    var offset: usize = 0;
    while (offset < lefts.len) {
        const end = @min(offset + chunk_size, lefts.len);
        const chunk = lefts[offset..end];
        offset = end;

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(allocator,
            \\SELECT d1.word AS word, b.frequency AS frequency
            \\FROM dictionary d1
            \\JOIN bigrams b ON b.w1_id = d1.id
            \\JOIN dictionary d2 ON d2.id = b.w2_id
            \\WHERE d2.word =
        );
        try appendSqlString(allocator, &sql, right);
        try sql.appendSlice(allocator, " AND d1.word IN (");
        for (chunk, 0..) |w, i| {
            if (i > 0) try sql.append(allocator, ',');
            try appendSqlString(allocator, &sql, w);
        }
        try sql.append(allocator, ')');

        const rows = try zx.db.rows(allocator, Spell.LexiconEntry, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryTrigrams(allocator: std.mem.Allocator, w1: []const u8, w2: []const u8, w3s: []const []const u8) ![]const Spell.LexiconEntry {
    const chunk_size = 80;
    var out: std.ArrayList(Spell.LexiconEntry) = .empty;
    var offset: usize = 0;
    while (offset < w3s.len) {
        const end = @min(offset + chunk_size, w3s.len);
        const chunk = w3s[offset..end];
        offset = end;

        var sql: std.ArrayList(u8) = .empty;
        try sql.appendSlice(allocator,
            \\SELECT d3.word AS word, t.frequency AS frequency
            \\FROM dictionary d1
            \\JOIN dictionary d2 ON d2.word =
        );
        try appendSqlString(allocator, &sql, w2);
        try sql.appendSlice(allocator,
            \\
            \\JOIN trigrams t ON t.w1_id = d1.id AND t.w2_id = d2.id
            \\JOIN dictionary d3 ON d3.id = t.w3_id
            \\WHERE d1.word =
        );
        try appendSqlString(allocator, &sql, w1);
        try sql.appendSlice(allocator, " AND d3.word IN (");
        for (chunk, 0..) |w, i| {
            if (i > 0) try sql.append(allocator, ',');
            try appendSqlString(allocator, &sql, w);
        }
        try sql.append(allocator, ')');

        const rows = try zx.db.rows(allocator, Spell.LexiconEntry, sql.items, .{});
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
