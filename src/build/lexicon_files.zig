//! Build-time: the committed `lexicon.zon` → the files other consumers load.
//!
//!   lexicon_files <lexicon.zon> <words.txt> <Dictionary.json>
//!
//! - `words.txt`: every word once, byte-sorted, one per line; `prepare` merges it
//!   into the spell lexicon.
//! - `Dictionary.json`: `{ "<table>": ["<word>", ...] }`, the shape the macOS
//!   SpellServer loads (it only takes the union of the lists).
//!
//! `lexicon.zon` itself is regenerated from iAvro by `lexicon.zig`.

const std = @import("std");
const Lexicon = @import("lexicon_type");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: {s} <lexicon.zon> <words.txt> <Dictionary.json>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();

    const source = try cwd.readFileAllocOptions(io, args[1], arena, .limited(64 * 1024 * 1024), .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const lexicon = std.zon.parse.fromSlice(Lexicon, .{
        .gpa = init.gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(args[1]);
        return err;
    };

    var json: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &json.writer };
    try stringify.beginObject();
    var words: std.ArrayList([]const u8) = .empty;
    for (lexicon.tables) |table| {
        try stringify.objectField(table.name);
        try stringify.write(table.words);
        try words.appendSlice(arena, table.words);
    }
    try stringify.endObject();

    std.mem.sort([]const u8, words.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var txt: std.ArrayList(u8) = .empty;
    for (words.items, 0..) |word, i| {
        if (i > 0 and std.mem.eql(u8, words.items[i - 1], word)) continue;
        try txt.appendSlice(arena, word);
        try txt.append(arena, '\n');
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = txt.items });
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = json.written() });
}
