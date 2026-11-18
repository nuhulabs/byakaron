//! Generator for the iOS keyboard's emoji picker data, run by `zig build gen -- ios-emoji`.
//!
//!   ios_emoji <emoji-test.txt> <EmojiData.swift>
//!
//! The picker lists every fully-qualified emoji in CLDR order, grouped the way
//! the system emoji keyboard groups them (Smileys & People together, Activity
//! before Travel & Places). Skin-tone variants are not listed; they are offered
//! on a long press of their base emoji instead. The source is Unicode's
//! emoji-test.txt (the one in apps/android/keyboard/tools/make-emoji-keys/
//! src/main/resources/emoji/ucd/<version>/), the output
//! apps/ios/keyboard/Keyboard/Models/EmojiData.swift.

const std = @import("std");

/// The system keyboard's categories, in its order.
const Category = enum { smileysAndPeople, animalsAndNature, foodAndDrink, activity, travelAndPlaces, objects, symbols, flags };

/// Unicode group → the system keyboard's category.
const groups = std.StaticStringMap(Category).initComptime(.{
    .{ "Smileys & Emotion", .smileysAndPeople },
    .{ "People & Body", .smileysAndPeople },
    .{ "Animals & Nature", .animalsAndNature },
    .{ "Food & Drink", .foodAndDrink },
    .{ "Activities", .activity },
    .{ "Travel & Places", .travelAndPlaces },
    .{ "Objects", .objects },
    .{ "Symbols", .symbols },
    .{ "Flags", .flags },
});

fn isTone(c: u21) bool {
    return c >= 0x1F3FB and c <= 0x1F3FF;
}

const Line = struct { codes: []const u8, version: []const u8 };

/// `1F600 ; fully-qualified # 😀 E1.0 grinning face` → the code points and
/// the version (`^([0-9A-F ]+?)\s*;\s*fully-qualified\s*#\s*\S+\s+E(\d+\.\d+)`).
fn parseLine(line: []const u8) ?Line {
    var i: usize = 0;
    while (i < line.len and (std.ascii.isDigit(line[i]) or (line[i] >= 'A' and line[i] <= 'F') or line[i] == ' ')) i += 1;
    if (i == 0 or i >= line.len or line[i] != ';') return null;
    const codes = std.mem.trimEnd(u8, line[0..i], " ");
    if (codes.len == 0) return null;
    var rest = std.mem.trimStart(u8, line[i + 1 ..], " \t");
    if (!std.mem.startsWith(u8, rest, "fully-qualified")) return null;
    rest = std.mem.trimStart(u8, rest["fully-qualified".len..], " \t");
    if (rest.len == 0 or rest[0] != '#') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    const emoji_end = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    if (emoji_end == 0) return null;
    rest = std.mem.trimStart(u8, rest[emoji_end..], " \t");
    if (rest.len == 0 or rest[0] != 'E') return null;
    rest = rest[1..];
    var j: usize = 0;
    while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
    if (j == 0 or j >= rest.len or rest[j] != '.') return null;
    var k = j + 1;
    while (k < rest.len and std.ascii.isDigit(rest[k])) k += 1;
    if (k == j + 1) return null;
    return .{ .codes = codes, .version = rest[0..k] };
}

/// "15.1" ≥ 15.0? (Emoji versions are major.minor.)
fn atLeast15(version: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, version, '.').?;
    const major = std.fmt.parseInt(u32, version[0..dot], 10) catch return true;
    return major >= 15;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <emoji-test.txt> <EmojiData.swift>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));

    var categories: [std.enums.values(Category).len]std.ArrayList([]const u8) = @splat(.empty);
    // Base emoji → its one-tone variants, in the order the bases first appear.
    var variants: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var group: ?Category = null;
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "# group:")) {
            group = groups.get(std.mem.trim(u8, line["# group:".len..], " \t"));
            continue;
        }
        const parsed = parseLine(line) orelse continue;
        const category = group orelse continue;

        var emoji: std.ArrayList(u8) = .empty;
        var base: std.ArrayList(u8) = .empty;
        var tone: ?u21 = null;
        var one_tone = true;
        var it = std.mem.tokenizeScalar(u8, parsed.codes, ' ');
        while (it.next()) |hex| {
            const c = try std.fmt.parseInt(u21, hex, 16);
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(c, &buf);
            try emoji.appendSlice(arena, buf[0..n]);
            if (isTone(c)) {
                if (tone != null and tone.? != c) one_tone = false;
                tone = c;
            } else try base.appendSlice(arena, buf[0..n]);
        }
        if (tone != null) {
            // Only the five one-tone variants of a base go in its picker.
            if (one_tone) {
                const gop = try variants.getOrPut(arena, base.items);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, emoji.items);
            }
            continue;
        }
        const entry = if (atLeast15(parsed.version))
            try std.fmt.allocPrint(arena, "{s}@{s}", .{ emoji.items, parsed.version })
        else
            emoji.items;
        try categories[@intFromEnum(category)].append(arena, entry);
        count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(
        \\// Generated by `zig build gen -- ios-emoji` from Unicode emoji-test.txt. Do not edit.
        \\
        \\/// Every emoji in the system keyboard's categories, space-separated in CLDR
        \\/// order. An emoji newer than Emoji 15.0 carries its version after an `@`.
        \\enum EmojiData {
        \\
    );
    for (std.enums.values(Category)) |category| {
        try w.print("    static let {t} = \"", .{category});
        for (categories[@intFromEnum(category)].items, 0..) |e, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(e);
        }
        try w.writeAll("\"\n");
    }
    try w.writeAll(
        \\
        \\    /// A base emoji, a tab, then its five skin-tone variants, one per line.
        \\    static let skinTones = """
        \\
    );
    for (variants.keys(), variants.values()) |base, tones| {
        if (tones.items.len != 5) continue;
        try w.print("    {s}\t", .{base});
        for (tones.items, 0..) |t, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(t);
        }
        try w.writeByte('\n');
    }
    try w.writeAll(
        \\    """
        \\}
        \\
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

test parseLine {
    const l = parseLine("1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face").?;
    try std.testing.expectEqualStrings("1F600", l.codes);
    try std.testing.expectEqualStrings("1.0", l.version);
    const m = parseLine("1F44B 1F3FB ; fully-qualified # 👋🏻 E1.0 waving hand: light skin tone").?;
    try std.testing.expectEqualStrings("1F44B 1F3FB", m.codes);
    try std.testing.expect(parseLine("263A ; unqualified # ☺ E0.6 smiling face") == null);
    try std.testing.expect(parseLine("# subgroup: face-smiling") == null);
}
