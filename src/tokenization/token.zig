const keywords: Keywords = @import("assets/keywords.zon");
const std = @import("std");

pub fn main() !void {
    std.debug.print("\nTotal: {}\n", .{keywords.characters.len});
    for (keywords.characters) |char| {
        // std.debug.print("{s}: {s}, Name: {s}, Kind: {s}, Unicode: U+{X:0>4} | ", .{
        //     char.code,
        //     char.value,
        //     char.name,
        //     @tagName(char.kind),
        //     char.value,
        // });
        std.debug.print("{s} ", .{char.value});
    }
    std.debug.print("Len: {}\nRange: {s}-{s}\n", .{
        keywords.characters.len,
        keywords.characters[0].code,
        keywords.characters[keywords.characters.len - 1].code,
    });

    var assigned: u8 = 0;
    for (keywords.characters) |char| {
        // std.debug.print("{}: {s}, Name: {s}, Kind: {s}, Unicode: U+{X:0>4} | ", .{
        //     char.code,
        //     char.value,
        //     char.name,
        //     @tagName(char.kind),
        //     char.value,
        // });

        std.debug.print("{s} ", .{char.value});
        if (char.kind != .unassigned) assigned += 1;
    }

    std.debug.print("\nTotal V2: {}\n", .{assigned});

    // Log all Bengali unicode chars from range without using Keywords list
    const bengali_start: u21 = 0x0980;
    const bengali_end: u21 = 0x09FF;

    // Generate and save V2 using range and find the name kind from keywords if available otherwise fallback value
    std.debug.print("\nAll Bengali Unicode Characters (U+0980 to U+09FF):\n", .{});
    var count: u8 = 0;
    for (bengali_start..bengali_end + 1) |current| {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(current), &utf8_buf) catch continue;
        const char = utf8_buf[0..len];
        // std.debug.print("U+{X:0>4}: {s} ", .{ current, char });
        std.debug.print("{s} ", .{char});

        count += 1;
    }

    std.debug.print("\nTotal: {}\n", .{count});

    const chard = "আমার";

    std.debug.print("{}", .{@TypeOf(chard)});
}
pub const KeywordKind = enum {
    consonant,
    vowel,
    vowel_sign,
    special,
    digit,
    symbol,
    number,
    unassigned,
};

pub const Keywords = struct {
    pub const Character = struct {
        code: u21,
        ucd: []const u8,
        value: []const u8,
        kind: KeywordKind,
        name: []const u8,
    };

    characters: []const Character,
};

fn findExistingCharecter(char: []const u8) !Keywords.Character {
    for (keywords.characters) |c| {
        if (std.mem.eql(u8, c.value, char)) return c;
    }

    return error.no_existing_character;
}

fn kindOrder(kind: KeywordKind) u8 {
    return switch (kind) {
        .vowel => 0,
        .consonant => 1,
        .vowel_sign => 2,
        .special => 3,
        .digit => 4,
        .symbol => 5,
        .number => 6,
        .unassigned => 7,
    };
}

fn compareCharacters(context: void, a: Keywords.Character, b: Keywords.Character) bool {
    _ = context;
    const order_a = kindOrder(a.kind);
    const order_b = kindOrder(b.kind);
    if (order_a != order_b) {
        return order_a < order_b;
    }
    return a.code < b.code;
}

test "sav eKeywordsV2" {
    // DEMO: Save patterns as Zon for experimental purposes

    var list = std.ArrayList(Keywords.Character).init(std.heap.page_allocator);
    defer list.deinit();

    // try list.append(.{ .code = 0x0981, .kind = .unassigned, .value = "TEST_VALUE", .name = "TEST_NAME" });
    var char_str = std.ArrayList(u8).init(std.heap.page_allocator);
    defer char_str.deinit();
    const bengali_start: u21 = 0x0980;
    const bengali_end: u21 = 0x09FF;
    for (bengali_start..bengali_end + 1) |current| {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(current), &utf8_buf) catch continue;
        const char = utf8_buf[0..len];

        const existing = findExistingCharecter(char) catch null;
        const value = std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{char}) catch unreachable;
        const ucd = std.fmt.allocPrint(std.heap.page_allocator, "U+{X:0>4}", .{current}) catch unreachable;

        if (existing) |e| {
            var lower_cased_underscored_name = std.ArrayList(u8).init(std.heap.page_allocator);
            defer lower_cased_underscored_name.deinit();
            for (e.name) |c| {
                if (c == ' ') {
                    lower_cased_underscored_name.append('_') catch unreachable;
                } else {
                    lower_cased_underscored_name.append(std.ascii.toLower(c)) catch unreachable;
                }
            }

            try list.append(.{
                .code = @intCast(current),
                .kind = e.kind,
                .value = value,
                .name = e.name,
                .ucd = ucd,
            });
        } else {
            try list.append(.{
                .code = @intCast(current),
                .kind = .unassigned,
                .value = value,
                .name = ucd,
                .ucd = ucd,
            });
        }
    }

    // Sort the list by kind and then by code
    std.mem.sort(Keywords.Character, list.items, {}, compareCharacters);

    const kwds = Keywords{ .characters = list.items };
    _ = kwds;

    // write json
    // var json_str = std.ArrayList(u8).init(std.heap.page_allocator);
    // defer json_str.deinit();
    // try std.json.stringify(kwds, .{
    //     .whitespace = .indent_2,
    //     .escape_unicode = false,
    // }, json_str.writer());
    // try std.fs.cwd().writeFile(.{
    //     .data = json_str.items,
    //     .sub_path = "patterns.json",
    // });

    // // write zon
    // var zon_str = std.ArrayList(u8).init(std.heap.page_allocator);
    // defer zon_str.deinit();
    // try std.zon.stringify.serialize(kwds, .{
    //     .emit_codepoint_literals = .never,
    //     .whitespace = false,
    // }, zon_str.writer());
    // try std.fs.cwd().writeFile(.{
    //     .data = zon_str.items,
    //     .sub_path = "patterns.zon",
    // });
}
