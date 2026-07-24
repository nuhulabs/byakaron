//! SQLite-backed `Spell.VTable` using `zx.Db.Sqlite`.
//!
//! Opens a lexicon database (dictionary / deletes / bigrams / confusions) and
//! exposes the same `Spell` engine API used by webz and the macOS FFI.

const Sqlite = @This();

const std = @import("std");
const Spell = @import("spell");
const zx = @import("zx");

allocator: std.mem.Allocator,
db: zx.Db,
spell: Spell,

/// Open `path` (plain filesystem path or `file:…` URL) and wrap it as a Spell backend.
pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Sqlite {
    const self = try allocator.create(Sqlite);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .db = try zx.Db.Sqlite.open(allocator, io, path, .{
            .readonly = true,
            .create = false,
            .readwrite = false,
            .max_pool_size = 1,
        }),
        .spell = undefined,
    };
    errdefer self.db.deinit();

    self.spell = Spell.init(&vtable, self);
    return self;
}

pub fn deinit(self: *Sqlite) void {
    self.db.deinit();
    self.allocator.destroy(self);
}

pub fn engine(self: *Sqlite) *Spell {
    return &self.spell;
}

const vtable = Spell.VTable{
    .lookup_words = lookupWords,
    .lookup_deletes = lookupDeletes,
    .prefix_suggest = prefixSuggestDb,
    .next_word_suggest = nextWordSuggestDb,
    .load_confusions = loadConfusions,
};

const ConfusionRow = struct {
    from_g: []const u8,
    to_g: []const u8,
    weight: f64,
};

fn asSelf(ctx: *anyopaque) *Sqlite {
    return @ptrCast(@alignCast(ctx));
}

fn lookupWords(ctx: *anyopaque, allocator: std.mem.Allocator, words: []const []const u8) ![]const Spell.LexiconEntry {
    return try asSelf(ctx).queryWordsIn(allocator, words);
}

fn lookupDeletes(ctx: *anyopaque, allocator: std.mem.Allocator, delete_keys: []const []const u8) ![]const Spell.DeleteLookupHit {
    return try asSelf(ctx).queryDeletesIn(allocator, delete_keys);
}

fn prefixSuggestDb(ctx: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Spell.LexiconEntry {
    const self = asSelf(ctx);
    const like = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    return try self.db.rows(allocator, Spell.LexiconEntry,
        \\SELECT word, frequency FROM dictionary
        \\WHERE word LIKE ?1
        \\ORDER BY frequency DESC
        \\LIMIT ?2
    , .{ like, limit });
}

fn nextWordSuggestDb(ctx: *anyopaque, allocator: std.mem.Allocator, previous_word: []const u8, limit: i64) ![]const Spell.LexiconEntry {
    const self = asSelf(ctx);
    return try self.db.rows(allocator, Spell.LexiconEntry,
        \\SELECT d2.word AS word, b.frequency AS frequency
        \\FROM dictionary d1
        \\JOIN bigrams b ON b.w1_id = d1.id
        \\JOIN dictionary d2 ON d2.id = b.w2_id
        \\WHERE d1.word = ?1
        \\ORDER BY b.frequency DESC
        \\LIMIT ?2
    , .{ previous_word, limit });
}

fn loadConfusions(ctx: *anyopaque, allocator: std.mem.Allocator) ![]const Spell.ConfusionRule {
    const self = asSelf(ctx);
    const rows = try self.db.rows(allocator, ConfusionRow,
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

/// `WHERE word IN ('a','b',...)` — literals avoid comptime-only bind tuples for dynamic lists.
fn queryWordsIn(self: *Sqlite, allocator: std.mem.Allocator, words: []const []const u8) ![]const Spell.LexiconEntry {
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
        const rows = try self.db.rows(allocator, Spell.LexiconEntry, sql.items, .{});
        try out.appendSlice(allocator, rows);
    }
    return try out.toOwnedSlice(allocator);
}

fn queryDeletesIn(self: *Sqlite, allocator: std.mem.Allocator, keys: []const []const u8) ![]const Spell.DeleteLookupHit {
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

        const rows = try self.db.rows(allocator, Spell.DeleteLookupHit, sql.items, .{});
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
