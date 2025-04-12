const std = @import("std");
const tokenization = @import("tokenization.zig");
const KeywordsV2 = tokenization.KeywordsV2;
const KeywordKind = tokenization.KeywordKind;

// Character ranges and categories
const CharCategory = struct {
    start: u21,
    end: u21,
    kind: KeywordKind,
};

fn createCategories() [8]CharCategory {
    return .{
        // Independent vowels
        .{ .start = 0x0985, .end = 0x0994, .kind = .vowel },
        // Consonants
        .{ .start = 0x0995, .end = 0x09B9, .kind = .consonant },
        // Dependent vowel signs
        .{ .start = 0x09BE, .end = 0x09CC, .kind = .vowel_sign },
        // Numbers
        .{ .start = 0x09E6, .end = 0x09EF, .kind = .digit },
        // Various signs and symbols (selective ranges)
        .{ .start = 0x0980, .end = 0x0983, .kind = .symbol },
        .{ .start = 0x09BC, .end = 0x09BD, .kind = .symbol },
        .{ .start = 0x09F2, .end = 0x09FB, .kind = .symbol },
        .{ .start = 0x09FC, .end = 0x09FE, .kind = .symbol },
    };
}

fn determineKind(code: u21) KeywordKind {
    const categories = createCategories();
    for (categories) |category| {
        if (code >= category.start and code <= category.end) {
            return category.kind;
        }
    }
    return .special;
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an ArrayList to store characters
    var list = std.ArrayList(KeywordsV2.Character).init(allocator);
    defer {
        for (list.items) |item| {
            allocator.free(item.value);
            allocator.free(item.name);
            allocator.free(item.ucd);
        }
        list.deinit();
    }

    // Define Bengali Unicode range
    const bengali_start: u21 = 0x0980;
    const bengali_end: u21 = 0x09FF;

    // Read the Unicode data file
    const file_content = try std.fs.cwd().readFileAlloc(allocator, "./tmp/UnicodeData.txt", std.math.maxInt(usize));
    defer allocator.free(file_content);

    var lines = std.mem.splitScalar(u8, file_content, '\n');
    while (lines.next()) |line| {
        // Parse each line
        var it = std.mem.splitScalar(u8, line, ';');
        const code_str = it.next() orelse continue;
        const name = it.next() orelse continue;

        // Convert hex code to number
        const code = try std.fmt.parseInt(u21, code_str, 16);

        // Skip if not in Bengali range
        if (code < bengali_start or code > bengali_end) continue;

        // Create UTF-8 string from code point
        var utf8_buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(code, &utf8_buf);
        const char = utf8_buf[0..len];

        // Allocate strings
        const value = try std.fmt.allocPrint(allocator, "{s}", .{char});
        const name_owned = try allocator.dupe(u8, name);
        const ucd = try std.fmt.allocPrint(allocator, "U+{X:0>4}", .{code});

        // Determine kind using the new classification system
        const kind = determineKind(code);

        try list.append(.{
            .code = code,
            .kind = kind,
            .value = value,
            .name = name_owned,
            .ucd = ucd,
        });
    }

    // Create KeywordsV2 struct
    const kwds = KeywordsV2{ .characters = list.items };

    // Write as ZON
    var zon_str = std.ArrayList(u8).init(allocator);
    defer zon_str.deinit();

    try std.zon.stringify.serialize(kwds, .{
        .emit_codepoint_literals = .printable_ascii,
        .whitespace = true,
    }, zon_str.writer());

    // Save to file
    try std.fs.cwd().writeFile(.{
        .sub_path = "src/assets/keywords_v2.zon",
        .data = zon_str.items,
    });
    // Save to json file
    var json_str = std.ArrayList(u8).init(allocator);
    defer json_str.deinit();
    try std.json.stringify(kwds, .{
        .whitespace = .indent_2,
        .escape_unicode = false,
    }, json_str.writer());
    try std.fs.cwd().writeFile(.{
        .sub_path = "src/assets/keywords_v2.json",
        .data = json_str.items,
    });

    std.debug.print("Successfully synced Bengali Unicode data to keywords_v2.zon\n", .{});
    std.debug.print("Total characters processed: {d}\n", .{list.items.len});
}
