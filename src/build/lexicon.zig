//! Build-time generator: iAvro data → lexicon files.
//!
//!   lexicon <database.db3> <autodict.dct> <words.txt> <Dictionary.json> <lexicon.zon>
//!
//! Inputs are from iAvro (github.com/omicronlab/iAvro): the word database (one
//! table per Latin onset — `A`, `BH`, `Khandatta`, … — with a `Words` column,
//! plus `Suffix`) and the autocorrect list `autodict.dct`.
//!
//! - `words.txt`: every word once, byte-sorted, one per line; `prepare` merges it
//!   into the spell lexicon.
//! - `Dictionary.json`: `{ "<table, lowercased>": ["<word>", ...] }`, the shape the
//!   macOS SpellServer loads.
//! - `lexicon.zon`: a `Lexicon` (see `AutoComplete/Lexicon.zig`), imported at
//!   compile time by `AutoComplete/Mem.zig`.

const std = @import("std");
const Lexicon = @import("lexicon_type");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) {
        std.debug.print("usage: {s} <database.db3> <autodict.dct> <words.txt> <Dictionary.json> <lexicon.zon>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();

    var db: ?*sqlite3 = null;
    const db_path = try arena.dupeSentinel(u8, args[1], 0);
    if (sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        std.debug.print("error: cannot open {s}: {s}\n", .{ args[1], sqlite3_errmsg(db) });
        return error.SqliteOpenFailed;
    }
    defer _ = sqlite3_close(db);

    const table_names = try column(arena, db.?,
        \\SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'Suffix' ORDER BY name
    );

    var json: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &json.writer };
    try stringify.beginObject();

    var tables: std.ArrayList(Lexicon.Table) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    for (table_names) |table| {
        const query = try std.fmt.allocPrint(arena, "SELECT Words FROM \"{s}\" WHERE Words != ''", .{table});
        const rows = try column(arena, db.?, query);
        const name = try std.ascii.allocLowerString(arena, table);

        try stringify.objectField(name);
        try stringify.beginArray();
        var table_words: std.ArrayList([]const u8) = .empty;
        for (rows) |raw| {
            // database.db3 has a stray newline inside one word ("রাজ\nযক্ষ্মা");
            // Bangla words never contain ASCII whitespace, so drop it.
            const word = try stripAsciiWhitespace(arena, raw);
            if (word.len == 0) continue;
            try stringify.write(word);
            try table_words.append(arena, word);
            const gop = try seen.getOrPut(arena, word);
            if (!gop.found_existing) try words.append(arena, word);
        }
        try stringify.endArray();
        try tables.append(arena, .{ .name = name, .words = sortedDistinct(table_words.items) });
    }
    try stringify.endObject();
    std.mem.sort(Lexicon.Table, tables.items, {}, struct {
        fn less(_: void, a: Lexicon.Table, b: Lexicon.Table) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    sortStrings(words.items);
    var txt: std.ArrayList(u8) = .empty;
    for (words.items) |word| {
        try txt.appendSlice(arena, word);
        try txt.append(arena, '\n');
    }

    // iAvro's `Suffix` table: English suffix → Bangla suffix.
    var suffixes: std.ArrayList(Lexicon.Suffix) = .empty;
    {
        const en = try column(arena, db.?, "SELECT English FROM Suffix");
        const bn = try column(arena, db.?, "SELECT Bangla FROM Suffix");
        for (en, bn) |k, v| try suffixes.append(arena, .{ .latin = k, .bangla = v });
        std.mem.sort(Lexicon.Suffix, suffixes.items, {}, struct {
            fn less(_: void, a: Lexicon.Suffix, b: Lexicon.Suffix) bool {
                return std.mem.order(u8, a.latin, b.latin) == .lt;
            }
        }.less);
    }

    // autodict.dct, read like iAvro's AutoCorrect.m (`fscanf("%s %[^\n]\n")`): a
    // key, then the rest of the line. A value that differs from its key is Avro
    // phonetic (iAvro transliterates it when loading).
    var autocorrect: std.ArrayList(Lexicon.Autocorrect) = .empty;
    {
        const src = try cwd.readFileAlloc(io, args[2], arena, .limited(16 * 1024 * 1024));
        var lines = std.mem.tokenizeAny(u8, src, "\r\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            const sp = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
            const key = trimmed[0..sp];
            const value = std.mem.trim(u8, trimmed[sp..], " \t");
            if (value.len == 0) continue;
            try autocorrect.append(arena, .{ .from = key, .to = value, .phonetic = !std.mem.eql(u8, key, value) });
        }
        std.mem.sort(Lexicon.Autocorrect, autocorrect.items, {}, struct {
            fn less(_: void, a: Lexicon.Autocorrect, b: Lexicon.Autocorrect) bool {
                return std.mem.order(u8, a.from, b.from) == .lt;
            }
        }.less);
    }

    const lexicon: Lexicon = .{ .tables = tables.items, .suffixes = suffixes.items, .autocorrect = autocorrect.items };
    var zon: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(lexicon, .{}, &zon.writer);
    try zon.writer.writeByte('\n');

    try cwd.writeFile(io, .{ .sub_path = args[3], .data = txt.items });
    try cwd.writeFile(io, .{ .sub_path = args[4], .data = json.written() });
    try cwd.writeFile(io, .{ .sub_path = args[5], .data = zon.written() });
}

/// `items` byte-sorted with duplicates removed (in place).
fn sortedDistinct(items: [][]const u8) []const []const u8 {
    sortStrings(items);
    var n: usize = 0;
    for (items) |w| {
        if (n > 0 and std.mem.eql(u8, items[n - 1], w)) continue;
        items[n] = w;
        n += 1;
    }
    return items[0..n];
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

fn stripAsciiWhitespace(arena: std.mem.Allocator, word: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, word, &std.ascii.whitespace) == null) return word;
    var out: std.ArrayList(u8) = .empty;
    for (word) |c| {
        if (!std.ascii.isWhitespace(c)) try out.append(arena, c);
    }
    return out.items;
}

/// All values of the first column of `sql`, as text.
fn column(arena: std.mem.Allocator, db: *sqlite3, sql: []const u8) ![]const []const u8 {
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK) {
        std.debug.print("error: {s}\n  {s}\n", .{ sqlite3_errmsg(db), sql });
        return error.SqlitePrepareFailed;
    }
    defer _ = sqlite3_finalize(stmt);

    var out: std.ArrayList([]const u8) = .empty;
    while (true) switch (sqlite3_step(stmt)) {
        SQLITE_ROW => {
            const text = sqlite3_column_text(stmt, 0) orelse continue;
            const len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
            try out.append(arena, try arena.dupe(u8, text[0..len]));
        },
        SQLITE_DONE => return out.items,
        else => {
            std.debug.print("error: {s}\n  {s}\n", .{ sqlite3_errmsg(db), sql });
            return error.SqliteStepFailed;
        },
    };
}

// ── sqlite3.h (amalgamation compiled in by build.zig) ───────────────────────

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY = 0x00000001;

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, len: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, col: c_int) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
