const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const json_parser = @import("json_parser.zig");
const expect = std.testing.expect;
const json = std.json;
const fs = std.fs;

pub const Transliteration = struct {
    const RuleMatch = json_parser.RuleMatch;
    const Rule = json_parser.Rule;
    const Pattern = json_parser.Pattern;

    patterns: []const Pattern,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Transliteration {
        return Transliteration{
            .patterns = try json_parser.loadRules(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Transliteration) void {
        // Free the patterns
        self.allocator.free(self.patterns);
    }

    const vowel: []const u8 = "aeiou";
    const consonant: []const u8 = "bcdfghjklmnpqrstvwxyz";
    const casesensitive: []const u8 = "oiudgjnrstyz";

    pub fn fixString(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var fixed = std.ArrayList(u8).init(allocator);
        defer fixed.deinit();

        for (input) |char| {
            if (isCaseSensitive(char)) {
                try fixed.append(char);
            } else {
                try fixed.append(std.ascii.toLower(char));
            }
        }
        return fixed.toOwnedSlice();
    }

    pub fn isVowel(c: u8) bool {
        for (vowel) |v| {
            if (std.ascii.toLower(c) == v) {
                return true;
            }
        }
        return false;
    }

    pub fn isConsonant(c: u8) bool {
        for (consonant) |con| {
            if (std.ascii.toLower(c) == con) {
                return true;
            }
        }
        return false;
    }

    pub fn isPunctuation(c: u8) bool {
        return !isVowel(c) and !isConsonant(c);
    }

    pub fn isExact(needle: []const u8, heystack: []const u8, start: usize, end: usize, not: bool) bool {
        if (start < 0 or end > heystack.len) {
            return not;
        }

        const substring = heystack[start..end];
        return (mem.eql(u8, substring, needle)) != not;
    }

    pub fn isCaseSensitive(c: u8) bool {
        for (casesensitive) |cs| {
            if (std.ascii.toLower(c) == cs) {
                return true;
            }
        }
        return false;
    }

    pub fn transliterate(text: []const u8, mode: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var trans = try Transliteration.init(allocator);
        defer trans.deinit();

        if (mem.eql(u8, mode, "avro")) {
            return try trans.avro(text, allocator);
        } else if (mem.eql(u8, mode, "orva")) {
            return try trans.orva(text, allocator);
        } else if (mem.eql(u8, mode, "banglish")) {
            return error.NotImplemented;
        } else if (mem.eql(u8, mode, "lishbang")) {
            return error.NotImplemented;
        } else {
            return error.InvalidMode;
        }
    }

    const TrieNode = struct {
        children: std.StringHashMap(*TrieNode),
        pattern: ?*const Pattern,
        isEndOfPattern: bool,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !*TrieNode {
            const node = try allocator.create(TrieNode);
            node.* = TrieNode{
                .children = std.StringHashMap(*TrieNode).init(allocator),
                .pattern = null,
                .isEndOfPattern = false,
                .allocator = allocator,
            };
            return node;
        }

        fn deinit(self: *TrieNode) void {
            var it = self.children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.children.deinit();
        }
    };

    const PatternWithIndex = struct {
        pattern: Pattern,
        index: usize,
    };

    fn buildTrie(patterns_list: []const Pattern, allocator: std.mem.Allocator) !*TrieNode {
        const root = try TrieNode.init(allocator);
        errdefer root.deinit();

        for (patterns_list) |*pattern| {
            var current = root;
            const find = pattern.find;
            var i: usize = 0;
            while (i < find.len) : (i += 1) {
                const key = find[i .. i + 1];
                const next_node = current.children.get(key) orelse blk: {
                    const new_node = try TrieNode.init(allocator);
                    errdefer new_node.deinit();
                    try current.children.put(key, new_node);
                    break :blk new_node;
                };
                current = next_node;
            }
            current.isEndOfPattern = true;
            current.pattern = pattern;
        }
        return root;
    }

    fn avro(self: *const Transliteration, text: []const u8, allocator: std.mem.Allocator) ![]u8 {
        const fixed = try fixString(text, allocator);
        defer allocator.free(fixed);

        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        const len = fixed.len;
        var currentIndex: usize = 0;

        const trie = try buildTrie(self.patterns, allocator);
        defer {
            trie.deinit();
            allocator.destroy(trie);
        }

        while (currentIndex < len) {
            var node = trie;
            var matchLength: usize = 0;
            var matchPattern: ?*const Pattern = null;
            var i: usize = currentIndex;

            while (i < len) {
                const key = fixed[i .. i + 1];
                const next_node = node.children.get(key) orelse break;
                if (next_node.isEndOfPattern) {
                    matchLength = i - currentIndex + 1;
                    matchPattern = next_node.pattern;
                }
                node = next_node;
                i += 1;
            }

            if (matchPattern) |pattern| {
                const endIndex = currentIndex + matchLength;
                const result = try processPattern(pattern.*, fixed, currentIndex, endIndex, allocator);
                try output.appendSlice(result.output);
                currentIndex = result.newIndex + 1;
                allocator.free(result.output);
            } else {
                try output.append(fixed[currentIndex]);
                currentIndex += 1;
            }
        }

        return output.toOwnedSlice();
    }

    fn processPattern(pattern: Pattern, chars: []const u8, startIndex: usize, endIndex: usize, allocator: std.mem.Allocator) !struct { output: []u8, newIndex: usize } {
        if (pattern.rules == null) {
            return .{ .output = try allocator.dupe(u8, pattern.replace), .newIndex = endIndex - 1 };
        }

        // In JavaScript, previousIndex can be negative, but in Zig we need to handle this differently
        const previousIndex: isize = @intCast(@as(isize, @intCast(startIndex)) - 1);

        for (pattern.rules.?) |rule| {
            var shouldReplace: bool = true;

            for (rule.matches) |match| {
                const isSuffix = mem.eql(u8, match.type, "suffix");
                // Check index is signed to handle negatives properly
                const checkIndex: isize = if (isSuffix) @intCast(endIndex) else previousIndex;
                const isNegative = if (match.scope) |scope| scope.len > 0 and scope[0] == '!' else false;
                const scope = if (match.scope) |s| if (isNegative) s[1..] else s else null;

                if (scope) |s| {
                    // Handle different scope types (similar to JS switch statement)
                    if (mem.eql(u8, s, "punctuation")) {
                        const hasPunctuation =
                            (checkIndex < 0 and !isSuffix) or
                            (checkIndex >= chars.len and isSuffix) or
                            (checkIndex >= 0 and checkIndex < chars.len and isPunctuation(chars[@intCast(checkIndex)]));

                        if (hasPunctuation == isNegative) {
                            shouldReplace = false;
                            break;
                        }
                    } else if (mem.eql(u8, s, "vowel")) {
                        const isVowelMatch =
                            ((checkIndex >= 0 and !isSuffix) or
                                (checkIndex < chars.len and isSuffix)) and
                            (checkIndex >= 0 and checkIndex < chars.len and isVowel(chars[@intCast(checkIndex)]));

                        if (isVowelMatch == isNegative) {
                            shouldReplace = false;
                            break;
                        }
                    } else if (mem.eql(u8, s, "consonant")) {
                        const isConsonantMatch =
                            ((checkIndex >= 0 and !isSuffix) or
                                (checkIndex < chars.len and isSuffix)) and
                            (checkIndex >= 0 and checkIndex < chars.len and isConsonant(chars[@intCast(checkIndex)]));

                        if (isConsonantMatch == isNegative) {
                            shouldReplace = false;
                            break;
                        }
                    } else if (mem.eql(u8, s, "exact")) {
                        if (match.value) |value| {
                            // Calculate start and end indices similar to JS
                            const s_index: isize = if (isSuffix)
                                @intCast(endIndex)
                            else
                                @intCast(@max(0, @as(isize, @intCast(startIndex)) - @as(isize, @intCast(value.len))));

                            const e_index: isize = if (isSuffix)
                                @intCast(@min(chars.len, endIndex + value.len))
                            else
                                @intCast(startIndex);

                            // Check if indices are valid
                            if (s_index >= 0 and e_index <= chars.len and s_index <= e_index) {
                                const isExactMatch = mem.eql(u8, chars[@intCast(s_index)..@intCast(e_index)], value);

                                if (isExactMatch == isNegative) {
                                    shouldReplace = false;
                                    break;
                                }
                            } else {
                                // Outside of valid range and not an exact match
                                if (!isNegative) {
                                    shouldReplace = false;
                                    break;
                                }
                            }
                        } else {
                            // No value to match with, can't be exact
                            if (!isNegative) {
                                shouldReplace = false;
                                break;
                            }
                        }
                    }
                }
            }

            if (shouldReplace) {
                return .{ .output = try allocator.dupe(u8, rule.replace), .newIndex = endIndex - 1 };
            }
        }
        return .{ .output = try allocator.dupe(u8, pattern.replace), .newIndex = endIndex - 1 };
    }

    fn orva(self: *const Transliteration, text: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var reversePatterns: std.ArrayList(Pattern) = std.ArrayList(Pattern).init(allocator);
        defer reversePatterns.deinit();

        for (self.patterns) |pattern| {
            if (pattern.replace.len > 0 and pattern.find.len > 0 and !mem.eql(u8, pattern.find, "o") and pattern.replace.len > 0) {
                try reversePatterns.append(.{ .find = pattern.replace, .replace = pattern.find, .rules = pattern.rules });
            }
        }

        const Context = struct {
            pub fn lessThan(context: @This(), a: Pattern, b: Pattern) bool {
                _ = context;
                return b.find.len > a.find.len;
            }
        };

        std.mem.sort(Pattern, reversePatterns.items, Context{}, Context.lessThan);

        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        const maxIterations = text.len * 2;
        var iterations: usize = 0;
        var cur: usize = 0;
        while (cur < text.len) {
            iterations += 1;
            if (iterations > maxIterations) {
                std.debug.print("Orva transliteration exceeded maximum iterations, breaking to prevent infinite loop\n", .{});
                break;
            }
            const start = cur;
            var matched: bool = false;
            for (reversePatterns.items) |pattern| {
                const end = cur + pattern.find.len;
                if (end > text.len) {
                    continue;
                }
                const segment = text[start..end];
                if (mem.eql(u8, segment, pattern.find)) {
                    try output.appendSlice(pattern.replace);
                    cur = end - 1;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try output.append(text[cur]);
            }
            cur += 1;
        }

        const result = try allocator.dupe(u8, output.items);
        var final_result = result;
        var temp_buffer: []u8 = undefined;

        // Helper function to do replacements
        const doReplace = struct {
            fn replace(alloc: std.mem.Allocator, input: []const u8, from: []const u8, to: []const u8) ![]u8 {
                // Count occurrences to calculate final size
                var count: usize = 0;
                var i: usize = 0;
                while (i < input.len) : (i += 1) {
                    if (i + from.len > input.len) break;
                    if (std.mem.eql(u8, input[i .. i + from.len], from)) {
                        count += 1;
                        i += from.len - 1;
                    }
                }

                // Allocate buffer for result
                const new_len = input.len - (count * from.len) + (count * to.len);
                const result_buffer = try alloc.alloc(u8, new_len);

                // Do the replacement
                var read_pos: usize = 0;
                var write_pos: usize = 0;
                while (read_pos < input.len) {
                    if (read_pos + from.len <= input.len and std.mem.eql(u8, input[read_pos .. read_pos + from.len], from)) {
                        @memcpy(result_buffer[write_pos .. write_pos + to.len], to);
                        read_pos += from.len;
                        write_pos += to.len;
                    } else {
                        result_buffer[write_pos] = input[read_pos];
                        read_pos += 1;
                        write_pos += 1;
                    }
                }

                return result_buffer;
            }
        }.replace;

        // Do all the replacements
        temp_buffer = try doReplace(allocator, final_result, "`", "");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "আ", "a");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "অ", "o");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "ই", "i");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "ঈ", "e");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "উ", "u");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "এ", "e");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "্", "");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "়", "");
        allocator.free(final_result);
        final_result = temp_buffer;

        temp_buffer = try doReplace(allocator, final_result, "উ", "u");
        allocator.free(final_result);
        final_result = temp_buffer;

        return final_result;
    }
};

// Helper function to load test data
fn loadTestData(allocator: std.mem.Allocator) !struct { avro_tests: []const json.Value, ligature_tests: json.ObjectMap, parsed: json.Parsed(json.Value) } {
    const file = try fs.cwd().openFile("src/transliteration.test.json", .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    const parsed = try json.parseFromSlice(json.Value, allocator, file_content, .{});
    errdefer parsed.deinit();

    const avro_tests = parsed.value.object.get("avro").?.array.items;
    const ligature_tests = parsed.value.object.get("ligature").?.object;

    return .{ .avro_tests = avro_tests, .ligature_tests = ligature_tests, .parsed = parsed };
}

// Test avro transliteration cases
// test "mode: debug test" {
//     const allocator = std.heap.page_allocator;
//     const result = try Transliteration.transliterate("A`", "avro", allocator);
//     const expected = "া";
//     defer allocator.free(result);
//     std.debug.print("\n\nExpect: {s}\nGot:    {s}\n", .{ expected, result });
//     try expect(mem.eql(u8, result, expected));
// }

// Test avro transliteration cases
test "mode: avro test cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    for (test_data.avro_tests) |test_case| {
        const orva = test_case.object.get("orva").?.string;
        const avroed = test_case.object.get("avroed").?.string;

        const result = try Transliteration.transliterate(orva, "avro", allocator);
        defer allocator.free(result);

        // std.debug.print("\nTest {d}: mode: avro test {d}: {s}..\n", .{ index, index + 1, orva[0..@min(6, orva.len)] });
        // std.debug.print("Expect: {s}\nGot:    {s}", .{ avroed, result });
        try expect(mem.eql(u8, result, avroed));
    }
}

// Test ligature transliteration cases
test "mode: avro ligature cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    var it = test_data.ligature_tests.iterator();
    var total_failed: usize = 0;
    var total_ligatures: usize = 0;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.string;
        total_ligatures += 1;

        const result = try Transliteration.transliterate(key, "avro", allocator);
        defer allocator.free(result);

        const isSame = std.mem.eql(u8, value, result);
        // std.debug.print("\n\n==> {s} ➜ {s}", .{ key, value });
        // if (isSame) {
        //     std.debug.print("\nExpect: {s}\nGot:    {s}\nMatched: {}", .{ value, result, isSame });
        // }
        if (!isSame) {
            total_failed += 1;
            // Print in red color
            std.debug.print("\n\n==> {s} ➜ {s}", .{ key, value });

            std.debug.print("\n\x1b[31mExpect: {s}\nGot:    {s}\nMatched: {}\x1b[0m", .{ value, result, isSame });
        }
    }

    std.debug.print("\n\nTotal: {d}\nFailed: {d}\n", .{ total_ligatures, total_failed });
}

// Performance test
test "performance test - should handle large text quickly" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    const first_avro = test_data.avro_tests[0];
    const sample_text = first_avro.object.get("orva").?.string;
    var large_text = std.ArrayList(u8).init(allocator);
    defer large_text.deinit();

    // Repeat the sample text 100 times
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try large_text.appendSlice(sample_text);
    }

    const start_time = std.time.nanoTimestamp();
    const result = try Transliteration.transliterate(large_text.items, "avro", allocator);
    defer allocator.free(result);
    const end_time = std.time.nanoTimestamp();

    const execution_time = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0; // Convert to milliseconds
    const execution_time_per_thousand_chars = (execution_time / @as(f64, @floatFromInt(large_text.items.len))) * 1000.0;

    // The function should process large text in reasonable time (e.g., under 10ms per 1000 chars)
    const ALLOWED_TIME_PER_THOUSAND_CHARS: f64 = 10.0;
    try expect(execution_time_per_thousand_chars < ALLOWED_TIME_PER_THOUSAND_CHARS);

    std.debug.print("\nTime Taken per 1000 chars: {d:.2}ms\n", .{execution_time_per_thousand_chars});

    // Verify the result is correct (check first few characters)
    const expected_prefix = first_avro.object.get("avroed").?.string;
    try expect(mem.startsWith(u8, result, expected_prefix));
}
