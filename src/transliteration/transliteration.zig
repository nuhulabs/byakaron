const std = @import("std");
const grammar = @import("rules.zig");

/// Provides transliteration capabilities between Latin and Bangla scripts.
///
/// This module implements multiple transliteration modes for converting between
/// Latin-based and Bangla writing systems:
///
/// - **avro**: Standard Avro Phonetic system (Latin → Bangla)
/// - **orva**: Reverse Avro system (Bangla → Latin)
/// - **banglish**: Informal phonetic system (not yet implemented)
/// - **lishbang**: English-speaker friendly system (not yet implemented)
///
/// The implementation uses an efficient trie-based pattern matching system
/// with contextual rules to handle the complexity of Bangla phonetics.
///
/// Example usage:
/// ```
/// const allocator = std.heap.page_allocator;
/// // Convert Latin text to Bangla using Avro Phonetic
/// const result = try Transliteration.transliterate("amar bangla", "avro", allocator);
/// defer allocator.free(result);
/// // result now contains "আমার বাংলা"
/// ```
pub const Transliteration = struct {
    const Mode = enum {
        avro,
        orva,
        banglish,
        lishbang,
    };

    allocator: std.mem.Allocator,
    rules: grammar.Grammar,
    trie: *TrieNode,
    mode: Mode,
    /// Initializes the Transliteration system.
    ///
    /// This constructor loads the transliteration rules and builds the pattern
    /// matching trie structure needed for efficient text processing.
    ///
    /// @param allocator Memory allocator for rule storage and trie construction
    /// @return A new Transliteration instance
    pub fn init(allocator: std.mem.Allocator, comptime mode: Mode) Transliteration {
        const rules: grammar.Grammar = comptime switch (mode) {
            .avro => @import("rules.zon"),
            .orva => @import("orva.zon"),
            .banglish => @import("rules.zon"),
            .lishbang => @import("rules.zon"),
        };
        const trie = buildTrie(allocator, rules) catch unreachable;
        errdefer {
            trie.deinit();
            allocator.destroy(trie);
        }

        return .{
            .rules = rules,
            .allocator = allocator,
            .trie = trie,
            .mode = mode,
        };
    }

    /// Cleans up resources used by the Transliteration system.
    ///
    /// Frees all allocated memory, including the pattern matching trie and rule patterns.
    /// Must be called when the Transliteration object is no longer needed.
    pub fn deinit(self: *Transliteration) void {
        self.trie.deinit();
        self.allocator.destroy(self.trie);
    }

    /// Transliterates text between Bangla and Latin scripts using various modes.
    ///
    /// ## Modes
    /// - **avro**: Most popular phonetic typing system for Bangla
    ///   ```
    ///   transliterate("amar sOnar bangla", "avro") // → "আমার সোনার বাংলা"
    ///   transliterate("jIbon", "avro") // → "জীবন"
    ///   ```
    ///
    /// - **orva**: Reverse transliteration from Bangla to Latin script (beta)
    ///   ```
    ///   transliterate("আমার সোনার বাংলা", "orva") // → "amar sOnar bangla"
    ///   transliterate("জীবন", "orva") // → "jIbon"
    ///   ```
    ///
    /// - **banglish**: Informal phonetic system matching common texting patterns (not yet implemented)
    ///   ```
    ///   transliterate("amar shonar bangla", "banglish") // → "আমার সোনার বাংলা"
    ///   transliterate("jibon", "banglish") // → "জীবন"
    ///   ```
    ///
    /// - **lishbang**: English-speaker friendly system with systematic mappings (not yet implemented)
    ///   ```
    ///   transliterate("ইট ইজ নট গুড।", "lishbang")     // → "It is not good."
    ///   transliterate("মাই নেইম ইজ আপন।", "lishbang") // → "My name is Apon."
    ///   ```
    ///
    /// @param text The input text to transliterate
    /// @param mode The transliteration mode: "avro", "orva", "banglish", or "lishbang"
    /// @param allocator Memory allocator for operation
    /// @return The transliterated text (caller owns the memory)
    /// @error InvalidMode if the specified mode is not recognized
    /// @error NotImplemented if the mode is recognized but not yet implemented
    pub fn transliterate(self: *Transliteration, text: []const u8) []u8 {
        return self.execute(text) catch unreachable;
    }

    /// Transliterates Latin script to Bangla using Avro Phonetic keyboard layout rules.
    ///
    /// Avro Phonetic is the most widely used phonetic typing method for Bangla text.
    /// It follows intuitive phonetic rules where you type words exactly as they sound.
    /// This implementation uses a trie-based pattern matching system for efficient
    /// character mapping with contextual rules.
    ///
    /// @param text The Latin script input text to convert to Bangla
    /// @param allocator Memory allocator for operation
    /// @return The transliterated Bangla text (caller owns the memory)
    fn execute(self: *Transliteration, text: []const u8) ![]u8 {
        const fixed = try self.normalizeInput(text, self.allocator);
        defer self.allocator.free(fixed);

        // Use a fixed buffer for output to reduce allocations, with capacity for expansion
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();
        try output.ensureTotalCapacity(fixed.len * 3); // Pre-allocate with more space for worst case

        const len = fixed.len;
        var currentIndex: usize = 0;

        // Reuse buffer for pattern output to avoid allocation in hot loop
        var result_buffer = std.ArrayList(u8).init(self.allocator);
        defer result_buffer.deinit();
        try result_buffer.ensureTotalCapacity(32); // Typical replacement size

        while (currentIndex < len) {
            var node = self.trie;
            var matchLength: usize = 0;
            var matchPattern: ?*const grammar.Pattern = null;
            var i: usize = currentIndex;

            // Fast trie traversal with direct character indexing
            while (i < len) {
                const char = fixed[i];
                const next_node = node.children[char] orelse break;
                if (next_node.isEndOfPattern) {
                    matchLength = i - currentIndex + 1;
                    matchPattern = next_node.pattern;
                }
                node = next_node;
                i += 1;
            }

            if (matchPattern) |pattern| {
                const endIndex = currentIndex + matchLength;
                // Clear buffer for reuse
                result_buffer.clearRetainingCapacity();

                const result = try self.processPattern(pattern.*, fixed, currentIndex, endIndex, &result_buffer);
                try output.appendSlice(result.output);
                currentIndex = result.newIndex + 1;
            } else {
                try output.append(fixed[currentIndex]);
                currentIndex += 1;
            }
        }

        return output.toOwnedSlice();
    }

    // Using a more efficient character-indexed trie node
    const TrieNode = struct {
        // Direct array indexing for ASCII characters (much faster than HashMap)
        children: [256]?*TrieNode,
        pattern: ?*const grammar.Pattern,
        isEndOfPattern: bool,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) !*TrieNode {
            const node = try allocator.create(TrieNode);

            // Initialize all children to null
            for (0..256) |i| {
                node.children[i] = null;
            }

            node.pattern = null;
            node.isEndOfPattern = false;
            node.allocator = allocator;

            return node;
        }

        fn deinit(self: *TrieNode) void {
            for (0..256) |i| {
                if (self.children[i]) |child| {
                    child.deinit();
                    self.allocator.destroy(child);
                }
            }
        }
    };

    fn buildTrie(
        allocator: std.mem.Allocator,
        rules: grammar.Grammar,
    ) !*TrieNode {
        const root = try TrieNode.init(allocator);
        errdefer root.deinit();

        for (rules.patterns) |*pattern| {
            var current = root;
            const find = pattern.find;
            var i: usize = 0;
            while (i < find.len) : (i += 1) {
                const char = find[i];
                if (current.children[char] == null) {
                    current.children[char] = try TrieNode.init(allocator);
                }
                current = current.children[char].?;
            }
            current.isEndOfPattern = true;
            current.pattern = pattern;
        }
        return root;
    }

    fn processPattern(
        self: *Transliteration,
        pattern: grammar.Pattern,
        chars: []const u8,
        startIndex: usize,
        endIndex: usize,
        result_buffer: *std.ArrayList(u8),
    ) !struct { output: []const u8, newIndex: usize } {
        if (pattern.rules == null) {
            try result_buffer.appendSlice(pattern.replace);
            return .{ .output = result_buffer.items, .newIndex = endIndex - 1 };
        }

        // In JavaScript, previousIndex can be negative, but in Zig we need to handle this differently
        const previousIndex: isize = @intCast(@as(isize, @intCast(startIndex)) - 1);

        for (pattern.rules.?) |rule| {
            var shouldReplace: bool = true;

            for (rule.matches) |match| {
                const isSuffix = match.type == .suffix;
                // Check index is signed to handle negatives properly
                const checkIndex: isize = if (isSuffix) @intCast(endIndex) else previousIndex;
                const isNegative = match.negative;
                const scope = match.scope;

                if (scope) |s| {
                    // Handle different scope types using switch statement
                    switch (s) {
                        .punctuation => {
                            const hasPunctuation =
                                (checkIndex < 0 and !isSuffix) or
                                (checkIndex >= chars.len and isSuffix) or
                                (checkIndex >= 0 and checkIndex < chars.len and self.isPunctuation(chars[@intCast(checkIndex)]));

                            if (hasPunctuation == isNegative) {
                                shouldReplace = false;
                                break;
                            }
                        },
                        .vowel => {
                            const isVowelMatch =
                                ((checkIndex >= 0 and !isSuffix) or
                                    (checkIndex < chars.len and isSuffix)) and
                                (checkIndex >= 0 and checkIndex < chars.len and self.isVowel(chars[@intCast(checkIndex)]));

                            if (isVowelMatch == isNegative) {
                                shouldReplace = false;
                                break;
                            }
                        },
                        .consonant => {
                            const isConsonantMatch =
                                ((checkIndex >= 0 and !isSuffix) or
                                    (checkIndex < chars.len and isSuffix)) and
                                (checkIndex >= 0 and checkIndex < chars.len and self.isConsonant(chars[@intCast(checkIndex)]));

                            if (isConsonantMatch == isNegative) {
                                shouldReplace = false;
                                break;
                            }
                        },
                        .exact => {
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
                                    const isExactMatch = std.mem.eql(u8, chars[@intCast(s_index)..@intCast(e_index)], value);

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
                        },
                    }
                }
            }

            if (shouldReplace) {
                try result_buffer.appendSlice(rule.replace);
                return .{ .output = result_buffer.items, .newIndex = endIndex - 1 };
            }
        }

        try result_buffer.appendSlice(pattern.replace);
        return .{ .output = result_buffer.items, .newIndex = endIndex - 1 };
    }

    // Pre-compute lowercase transformation table for faster case conversion
    const lowercase_table = blk: {
        var table: [256]u8 = undefined;
        var i: u16 = 0;
        while (i < 256) : (i += 1) {
            table[i] = std.ascii.toLower(@intCast(i));
        }
        break :blk table;
    };

    fn normalizeInput(self: *Transliteration, input: []const u8, allocator: std.mem.Allocator) ![]u8 {
        var fixed = try allocator.alloc(u8, input.len);
        errdefer allocator.free(fixed);

        for (input, 0..) |char, i| {
            if (self.isCaseSensitive(char)) {
                fixed[i] = char;
            } else {
                fixed[i] = lowercase_table[char];
            }
        }
        return fixed;
    }

    fn isVowel(self: *Transliteration, c: u8) bool {
        if (self.mode == .orva) {
            return self.rules.vowel.isSet(c);
        }
        return self.rules.vowel.isSet(lowercase_table[c]);
    }

    fn isConsonant(self: *Transliteration, c: u8) bool {
        if (self.mode == .orva) {
            return self.rules.consonant.isSet(c);
        }
        return self.rules.consonant.isSet(lowercase_table[c]);
    }

    fn isPunctuation(self: *Transliteration, c: u8) bool {
        return !self.isVowel(c) and !self.isConsonant(c);
    }

    fn isExact(needle: []const u8, heystack: []const u8, start: usize, end: usize, not: bool) bool {
        if (start < 0 or end > heystack.len) {
            return not;
        }

        const substring = heystack[start..end];
        return (std.mem.eql(u8, substring, needle)) != not;
    }
    fn isCaseSensitive(self: *Transliteration, c: u8) bool {
        if (self.mode == .orva) {
            return self.rules.casesensitive.isSet(c);
        }
        return self.rules.casesensitive.isSet(lowercase_table[c]);
    }
};

// ------------ TESTING ------------
const expect = std.testing.expect;
const assert = std.debug.assert;
const testing = std.testing;

// Helper function to load test data
fn loadTestData(allocator: std.mem.Allocator) !struct { avro_tests: []const std.json.Value, ligature_tests: std.json.ObjectMap, parsed: std.json.Parsed(std.json.Value) } {
    const file = try std.fs.cwd().openFile("src/assets/transliteration.test.json", .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_content, .{});
    errdefer parsed.deinit();

    const avro_tests = parsed.value.object.get("samples").?.array.items;
    const ligature_tests = parsed.value.object.get("ligature").?.object;

    return .{ .avro_tests = avro_tests, .ligature_tests = ligature_tests, .parsed = parsed };
}

test "mode: debug test" {
    const allocator = std.heap.page_allocator;
    var transliteratior = Transliteration.init(allocator, .avro);
    defer transliteratior.deinit();

    const result = transliteratior.transliterate("A`");
    const expected = "া";
    defer allocator.free(result);
    // std.debug.print("\n\nExpect: {s}\nGot:    {s}\n", .{ expected, result });
    try testing.expectEqualStrings(result, expected);
}

test "mode: avro test cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    var transliteratior = Transliteration.init(allocator, .avro);
    for (test_data.avro_tests) |test_case| {
        const en = test_case.object.get("en").?.string;
        const bn = test_case.object.get("bn").?.string;

        const result = transliteratior.transliterate(en);
        defer allocator.free(result);

        // std.debug.print("\nTest {d}: mode: avro test {d}: {s}..\n", .{ index, index + 1, orva[0..@min(6, orva.len)] });
        // std.debug.print("Expect: {s}\nGot:    {s}", .{ avroed, result });
        try testing.expectEqualStrings(bn, result);
    }
}

test "mode: orva test cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    var transliteratior = Transliteration.init(allocator, .orva);
    for (test_data.avro_tests) |test_case| {
        const en = test_case.object.get("en").?.string;
        const bn = test_case.object.get("bn").?.string;

        const result = transliteratior.transliterate(bn);
        defer allocator.free(result);

        // std.debug.print("\nTest {d}: mode: avro test {d}: {s}..\n", .{ index, index + 1, orva[0..@min(6, orva.len)] });
        // std.debug.print("Expect: {s}\nGot:    {s}", .{ avroed, result });
        try testing.expectEqualStrings(en, result);
    }
}

test "mode: avro ligature cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    var transliteratior = Transliteration.init(allocator, .avro);
    var it = test_data.ligature_tests.iterator();
    var total_failed: usize = 0;
    var total_ligatures: usize = 0;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.string;
        total_ligatures += 1;

        const result = transliteratior.transliterate(key);
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

test "performance test - should handle large text quickly" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    const first_avro = test_data.avro_tests[0];
    const sample_text = first_avro.object.get("en").?.string;
    var large_text = std.ArrayList(u8).init(allocator);
    defer large_text.deinit();

    // Repeat the sample text 1000 times
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try large_text.appendSlice(sample_text);
    }

    var transliteratior = Transliteration.init(allocator, .avro);
    var total_time: f64 = 0;
    const NUM_RUNS = 20;

    // Run 10 times and calculate average
    var run: usize = 0;
    while (run < NUM_RUNS) : (run += 1) {
        const start_time = std.time.nanoTimestamp();
        const result = transliteratior.transliterate(large_text.items);
        defer allocator.free(result);
        const end_time = std.time.nanoTimestamp();

        const execution_time = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0; // Convert to milliseconds
        total_time += execution_time;

        // Verify the result is correct (check first few characters)
        const expected_prefix = first_avro.object.get("bn").?.string;
        try expect(std.mem.startsWith(u8, result, expected_prefix));
    }

    const avg_execution_time = total_time / @as(f64, @floatFromInt(NUM_RUNS));
    const avg_execution_time_per_thousand_chars = (avg_execution_time / @as(f64, @floatFromInt(large_text.items.len))) * 1000.0;

    // The function should process large text in reasonable time (e.g., under 10ms per 1000 chars)
    const ALLOWED_TIME_PER_THOUSAND_CHARS: f64 = 0.1;
    try expect(avg_execution_time_per_thousand_chars < ALLOWED_TIME_PER_THOUSAND_CHARS);

    std.debug.print("\nAverage Time Taken per 1000 chars: {d:.2}ms\n", .{avg_execution_time_per_thousand_chars});
}
