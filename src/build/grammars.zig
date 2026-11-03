//! Regenerate the committed grammars from iAvro (github.com/omicronlab/iAvro,
//! pinned in build.zig.zon):
//!
//!   grammars <data.json> <regex.json> <orva.zon> <rules.zon> <search.zon> <orva.zon>
//!
//! - `src/transliteration/rules.zon` ← iAvro `data.json`: Avro Phonetic, the
//!   rules `Transliteration` (`.avro`) runs.
//! - `src/AutoComplete/search.zon` ← iAvro `regex.json`: the phonetic search
//!   grammar `AutoComplete/Pattern.zig` turns a Latin term into a pattern with.
//! - `src/transliteration/orva.zon`: ours (Bangla → Latin), only rewritten in
//!   canonical form.
//!
//! Output is `std.zon` with Bangla as plain UTF-8, so the grammars stay readable
//! and diffable. Run through `zig build grammars`, which writes the results back
//! over the source files; nothing in the build reads iAvro's JSON directly.

const std = @import("std");
const Grammar = @import("transliteration").Grammar;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) {
        std.debug.print("usage: {s} <data.json> <regex.json> <orva.zon> <rules.zon> <search.zon> <orva.zon>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(16 * 1024 * 1024);

    for ([_][2][]const u8{ .{ args[1], args[4] }, .{ args[2], args[5] } }) |io_pair| {
        const json = try cwd.readFileAlloc(io, io_pair[0], arena, limit);
        try write(arena, io, io_pair[1], try fromJson(arena, json));
    }

    const source = try cwd.readFileAllocOptions(io, args[3], arena, limit, .of(u8), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const orva = std.zon.parse.fromSlice(Grammar, .{
        .gpa = init.gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(args[3]);
        return err;
    };
    try write(arena, io, args[6], orva);
}

fn write(arena: std.mem.Allocator, io: std.Io, path: []const u8, grammar: Grammar) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(grammar, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// iAvro grammar JSON → `Grammar`. Its booleans are Objective-C style strings
/// ("YES"/"NO", "TRUE"/"FALSE"); empty values and rule lists are left out.
fn fromJson(arena: std.mem.Allocator, src: []const u8) !Grammar {
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{})).object;

    var patterns: std.ArrayList(Grammar.Pattern) = .empty;
    for (root.get("patterns").?.array.items) |p| {
        var rules: std.ArrayList(Grammar.Rule) = .empty;
        if (p.object.get("rules")) |rs| for (rs.array.items) |r| {
            var matches: std.ArrayList(Grammar.RuleMatch) = .empty;
            for (r.object.get("matches").?.array.items) |m| {
                const value = if (m.object.get("value")) |v| v.string else "";
                try matches.append(arena, .{
                    .type = std.meta.stringToEnum(Grammar.RuleMatch.Type, m.object.get("type").?.string).?,
                    .scope = if (m.object.get("scope")) |s| std.meta.stringToEnum(Grammar.RuleMatch.Scope, s.string) else null,
                    .negative = if (m.object.get("negative")) |n| truthy(n) else false,
                    .value = if (value.len > 0) value else null,
                });
            }
            try rules.append(arena, .{ .matches = matches.items, .replace = r.object.get("replace").?.string });
        };
        try patterns.append(arena, .{
            .find = p.object.get("find").?.string,
            .replace = p.object.get("replace").?.string,
            .rules = if (rules.items.len > 0) rules.items else null,
        });
    }
    return .{
        .vowel = root.get("vowel").?.string,
        .consonant = root.get("consonant").?.string,
        .casesensitive = root.get("casesensitive").?.string,
        .patterns = patterns.items,
    };
}

fn truthy(v: std.json.Value) bool {
    return switch (v) {
        .bool => |b| b,
        .string => |s| std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "true"),
        else => false,
    };
}
