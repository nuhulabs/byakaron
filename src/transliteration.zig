const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const json_parser = @import("json_parser.zig");

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
        std.debug.print("Building trie with {} patterns\n", .{patterns_list.len});
        const root = try TrieNode.init(allocator);
        errdefer root.deinit();

        for (patterns_list, 0..) |*pattern, idx| {
            std.debug.print("Processing pattern {d}: {s}\n", .{ idx, pattern.find });
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
        std.debug.print("Trie construction completed\n", .{});
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
            // Special case for initial 'a'
            if (currentIndex == 0 and fixed[currentIndex] == 'a') {
                try output.appendSlice("আ");
                currentIndex += 1;
                continue;
            }

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

        const previousIndex = if (startIndex > 0) startIndex - 1 else 0;

        for (pattern.rules.?) |rule| {
            var shouldReplace: bool = true;

            for (rule.matches) |match| {
                const checkIndex = if (mem.eql(u8, match.type, "suffix")) endIndex else previousIndex;
                const isNegative = if (match.scope) |scope| scope[0] == '!' else false;
                const scope = if (match.scope) |s| if (isNegative) s[1..] else s else null;

                const isValid: bool = blk: {
                    if (scope) |s| {
                        if (mem.eql(u8, s, "punctuation")) {
                            if (checkIndex >= chars.len) {
                                break :blk true;
                            }
                            break :blk isPunctuation(chars[checkIndex]);
                        } else if (mem.eql(u8, s, "vowel")) {
                            if (checkIndex >= chars.len) {
                                break :blk false;
                            }
                            break :blk isVowel(chars[checkIndex]);
                        } else if (mem.eql(u8, s, "consonant")) {
                            if (checkIndex >= chars.len) {
                                break :blk false;
                            }
                            break :blk isConsonant(chars[checkIndex]);
                        } else if (mem.eql(u8, s, "exact")) {
                            if (match.value) |value| {
                                const s_index = if (mem.eql(u8, match.type, "suffix")) endIndex else if (value.len > startIndex) 0 else startIndex - value.len;
                                const e_index = if (mem.eql(u8, match.type, "suffix")) @min(endIndex + value.len, chars.len) else startIndex;

                                if (s_index >= chars.len or e_index > chars.len or s_index > e_index) {
                                    break :blk false;
                                }

                                if (mem.eql(u8, chars[s_index..e_index], value)) {
                                    break :blk true;
                                }
                                break :blk false;
                            }
                            break :blk false;
                        }
                    }
                    break :blk false;
                };

                if (isValid == isNegative) {
                    shouldReplace = false;
                    break;
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

const expect = std.testing.expect;

test "avro transliteration" {
    const allocator = std.heap.page_allocator;
    std.debug.print("\nInitializing test...\n", .{});

    var trans = try Transliteration.init(allocator);
    std.debug.print("Transliteration initialized\n", .{});
    defer trans.deinit();

    std.debug.print("Starting transliteration...\n", .{});
    const result = try trans.avro("ami banglay gan gai", allocator);
    std.debug.print("Transliteration completed\n", .{});
    defer allocator.free(result);

    std.debug.print("\nExpected: আমি বাংলায় গান গাই\nGot: {s}\n", .{result});
    try expect(mem.eql(u8, result, "আমি বাংলায় গান গাই"));
}

// test "avro transliteratio - advance" {
//     const orva = "kemon achO bondhoo, onek din por dekha ami banglaY likhte khoob pochondo kori. bangla bhaSha amader matrribhaSha. eTar modhZe onek soondor soondor kobita O golpo ache. ami ceShTa kori sob somoY shooddho banglaY kotha bolte. ami jani, bangla bZakaroNe onek zooktakkhor ache, za likhte ekoTu koThin. kintu, ami segoolO shikhte cai. ami procoor boi poRi, za amake bangla bhaSha sombndhe arO beshi janote sahazZo kore. ami bisheSh kore robIndronath Thakoorer kobita O golp poRi, zar modhZe ononto prem O prkrritir chobi ache. ami biswas kori, bangla bhasa amader sobaike ek sootOY ba^dhe. ami ei bhaSha niYe gorrbo bOdh kori. ami asha kori, amora sobai mile bangla bhaShake arO unnoto korbO.";
//     const avroed = "কেমন আছো বন্ধু, অনেক দিন পর দেখা আমি বাংলায় লিখতে খুব পছন্দ করি। বাংলা ভাষা আমাদের মাতৃভাষা। এটার মধ্যে অনেক সুন্দর সুন্দর কবিতা ও গল্প আছে। আমি চেষ্টা করি সব সময় শুদ্ধ বাংলায় কথা বলতে। আমি জানি, বাংলা ব্যাকারণে অনেক যুক্তাক্ষর আছে, যা লিখতে একটু কঠিন। কিন্তু, আমি সেগুলো শিখতে চাই। আমি প্রচুর বই পড়ি, যা আমাকে বাংলা ভাষা সম্বন্ধে আরো বেশি জানতে সাহায্য করে। আমি বিশেষ করে রবীন্দ্রনাথ ঠাকুরের কবিতা ও গল্প পড়ি, যার মধ্যে অনন্ত প্রেম ও প্রকৃতির ছবি আছে। আমি বিস্বাস করি, বাংলা ভাসা আমাদের সবাইকে এক সুতোয় বাঁধে। আমি এই ভাষা নিয়ে গর্ব বোধ করি। আমি আশা করি, আমরা সবাই মিলে বাংলা ভাষাকে আরো উন্নত করবো।";

//     const allocator = std.heap.page_allocator;
//     const result = try Transliteration.transliterate(orva, "avro", allocator);
//     defer allocator.free(result);
//     std.debug.print("\nExpected: {s}\nGot: {s}\n", .{ avroed, result });
//     try expect(mem.eql(u8, result, avroed));
// }
