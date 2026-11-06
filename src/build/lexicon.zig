//! Resync generator: iAvro data → the committed `src/AutoComplete/lexicon.zon`.
//!
//!   lexicon <database.db3> <autodict.dct> <lexicon.zon>
//!
//! Inputs are from iAvro (github.com/omicronlab/iAvro): the word database (one
//! table per Latin onset — `A`, `BH`, `Khandatta`, … — with a `Words` column,
//! plus `Suffix`) and the autocorrect list `autodict.dct`. Output is a `Lexicon`
//! (see `AutoComplete/Lexicon.zig`), imported at compile time by
//! `AutoComplete/Mem.zig`. Run through `zig build grammars -Diavro`;
//! `lexicon_files.zig` derives the word list and Dictionary.json from it.

const std = @import("std");
const Lexicon = @import("lexicon_type");
const sql = @import("sql");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: {s} <database.db3> <autodict.dct> <lexicon.zon>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();

    var db = try sql.open(init.gpa, io, args[1], .read_only);
    defer db.deinit();

    const table_names = try sql.column(arena, db,
        \\SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'Suffix' ORDER BY name
    );

    var tables: std.ArrayList(Lexicon.Table) = .empty;
    for (table_names) |table| {
        const query = try std.fmt.allocPrint(arena, "SELECT Words FROM \"{s}\" WHERE Words != ''", .{table});
        const rows = try sql.column(arena, db, query);
        var table_words: std.ArrayList([]const u8) = .empty;
        for (rows) |raw| {
            // database.db3 has a stray newline inside one word ("রাজ\nযক্ষ্মা");
            // Bangla words never contain ASCII whitespace, so drop it.
            const word = try stripAsciiWhitespace(arena, raw);
            if (word.len == 0) continue;
            try table_words.append(arena, word);
        }
        const name = try std.ascii.allocLowerString(arena, table);
        try tables.append(arena, .{ .name = name, .words = sortedDistinct(table_words.items) });
    }
    std.mem.sort(Lexicon.Table, tables.items, {}, struct {
        fn less(_: void, a: Lexicon.Table, b: Lexicon.Table) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);

    // iAvro's `Suffix` table: English suffix → Bangla suffix.
    var suffixes: std.ArrayList(Lexicon.Suffix) = .empty;
    {
        const rows = try db.all(arena, "SELECT English, Bangla FROM Suffix", .{});
        for (rows) |row| try suffixes.append(arena, .{ .latin = row.text("English"), .bangla = row.text("Bangla") });
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
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = zon.written() });
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
