//! Build-time generator: OmicronLab Avro `database.db3` → lexicon files.
//!
//!   avro_dictionary <database.db3> <words.txt> <Dictionary.json>
//!
//! Input is iAvro's word database (github.com/omicronlab/iAvro): one table per
//! Latin onset (`A`, `BH`, `Khandatta`, …) with a `Words` column, plus `Suffix`.
//!
//! - `words.txt`: every word once, byte-sorted, one per line. `AutoComplete/Mem.zig`
//!   binary-searches it and `prepare` merges it into the spell lexicon.
//! - `Dictionary.json`: `{ "<table, lowercased>": ["<word>", ...] }`, the shape the
//!   macOS SpellServer loads.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: {s} <database.db3> <words.txt> <Dictionary.json>\n", .{args[0]});
        return error.InvalidArguments;
    }

    var db: ?*sqlite3 = null;
    const db_path = try arena.dupeSentinel(u8, args[1], 0);
    if (sqlite3_open_v2(db_path, &db, SQLITE_OPEN_READONLY, null) != SQLITE_OK) {
        std.debug.print("error: cannot open {s}: {s}\n", .{ args[1], sqlite3_errmsg(db) });
        return error.SqliteOpenFailed;
    }
    defer _ = sqlite3_close(db);

    const tables = try column(arena, db.?,
        \\SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'Suffix' ORDER BY name
    );

    var json: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &json.writer };
    try stringify.beginObject();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    for (tables) |table| {
        const query = try std.fmt.allocPrint(arena, "SELECT Words FROM \"{s}\" WHERE Words != ''", .{table});
        const rows = try column(arena, db.?, query);

        try stringify.objectField(try std.ascii.allocLowerString(arena, table));
        try stringify.beginArray();
        for (rows) |raw| {
            // database.db3 has a stray newline inside one word ("রাজ\nযক্ষ্মা");
            // Bangla words never contain ASCII whitespace, so drop it.
            const word = try stripAsciiWhitespace(arena, raw);
            if (word.len == 0) continue;
            try stringify.write(word);
            const gop = try seen.getOrPut(arena, word);
            if (!gop.found_existing) try words.append(arena, word);
        }
        try stringify.endArray();
    }
    try stringify.endObject();

    std.mem.sort([]const u8, words.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var txt: std.ArrayList(u8) = .empty;
    for (words.items) |word| {
        try txt.appendSlice(arena, word);
        try txt.append(arena, '\n');
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = txt.items });
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = json.written() });
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
