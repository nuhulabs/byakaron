//! Provides transliteration capabilities between Latin and Bangla scripts.
//!
//! This module implements multiple transliteration modes for converting between
//! Latin-based and Bangla writing systems:
//!
//! - **avro**: Standard Avro Phonetic system (Latin → Bangla)
//! - **orva**: Reverse Avro system (Bangla → Latin)
//! - **banglish**: Informal phonetic system (not yet implemented)
//! - **lishbang**: English-speaker friendly system (not yet implemented)
//!
//! The implementation uses an efficient trie-based pattern matching system
//! with contextual rules to handle the complexity of Bangla phonetics.
//!
//! Example usage:
//! ```
//! const allocator = std.heap.page_allocator;
//! // Convert Latin text to Bangla using Avro Phonetic
//! var t = Transliteration.init(allocator, .avro);
//! defer t.deinit();
//! const result = t.transliterate("amar bangla");
//! defer allocator.free(result);
//! // result now contains "আমার বাংলা"
//! ```

const Transliteration = @This();

const std = @import("std");

const UNICODE_BITSET_SIZE = 0x2100;

/// Hasanta / virama (্): joins consonants and suppresses the inherent vowel.
const HASANTA: u21 = 0x09CD;

// Helper functions to populate bitsets
fn populateUnicodeSet(data: []const u8) std.StaticBitSet(UNICODE_BITSET_SIZE) {
    var set = std.StaticBitSet(UNICODE_BITSET_SIZE).empty;
    const utf = std.unicode.Utf8View.init(data) catch unreachable;
    var iter = utf.iterator();
    while (iter.nextCodepoint()) |codepoint| {
        // The lists are space-separated and include conjuncts (ক্ষ, ্য): neither
        // the separator nor the hasanta belongs to a letter class, and counting
        // them hides word ends and conjuncts from the inherent-vowel rules.
        if (codepoint == ' ' or codepoint == HASANTA) continue;
        set.set(codepoint);
    }
    return set;
}

fn populateAsciiSet(data: []const u8) std.StaticBitSet(256) {
    var set = std.bit_set.Static(256).empty;
    for (data) |char| {
        set.set(char); // Store lowercase for ASCII
    }
    return set;
}

pub const Mode = enum {
    avro,
    orva,
    banglish,
    lishbang,
};

const PhoneticSets = union(enum) {
    ascii: struct {
        vowel: std.StaticBitSet(256),
        consonant: std.StaticBitSet(256),
        casesensitive: std.StaticBitSet(256),
    },
    unicode: struct {
        vowel: std.StaticBitSet(UNICODE_BITSET_SIZE),
        consonant: std.StaticBitSet(UNICODE_BITSET_SIZE),
        casesensitive: std.StaticBitSet(UNICODE_BITSET_SIZE),
    },

    fn init(comptime mode: Mode) PhoneticSets {
        const rules: Grammar = comptime switch (mode) {
            .avro => @import("rules.zon"),
            .orva => @import("orva.zon"),
            .banglish => @import("rules.zon"),
            .lishbang => @import("rules.zon"),
        };

        if (mode == .orva) {
            @setEvalBranchQuota(30000);
            return PhoneticSets{ .unicode = .{
                .vowel = populateUnicodeSet(rules.vowel),
                .consonant = populateUnicodeSet(rules.consonant),
                .casesensitive = populateUnicodeSet(rules.casesensitive),
            } };
        } else {
            return PhoneticSets{ .ascii = .{
                .vowel = populateAsciiSet(rules.vowel),
                .consonant = populateAsciiSet(rules.consonant),
                .casesensitive = populateAsciiSet(rules.casesensitive),
            } };
        }
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

    fn isVowel(self: PhoneticSets, char: u21) bool {
        return switch (self) {
            .ascii => |sets| sets.vowel.isSet(lowercase_table[@intCast(char)]),
            .unicode => |sets| if (char >= UNICODE_BITSET_SIZE) false else sets.vowel.isSet(char),
        };
    }

    fn isConsonant(self: PhoneticSets, char: u21) bool {
        return switch (self) {
            .ascii => |sets| sets.consonant.isSet(lowercase_table[@intCast(char)]),
            .unicode => |sets| if (char >= UNICODE_BITSET_SIZE) false else sets.consonant.isSet(char),
        };
    }

    fn isCaseSensitive(self: PhoneticSets, char: u21) bool {
        return switch (self) {
            .ascii => |sets| sets.casesensitive.isSet(lowercase_table[@intCast(char)]),
            .unicode => |sets| if (char >= UNICODE_BITSET_SIZE) false else sets.casesensitive.isSet(char),
        };
    }

    fn isPunctuation(self: PhoneticSets, char: u21) bool {
        return !self.isVowel(char) and !self.isConsonant(char);
    }
};

allocator: std.mem.Allocator,
phonetic_sets: PhoneticSets,
rules: Grammar,
trie: *TrieNode,
unicode_trie: *UnicodeTrieNode,
mode: Mode,

/// Initializes the Transliteration system.
///
/// This constructor loads the transliteration rules and builds the pattern
/// matching trie structure needed for efficient text processing.
///
/// @param allocator Memory allocator for rule storage and trie construction
/// @return A new Transliteration instance
pub fn init(allocator: std.mem.Allocator, comptime mode: Mode) Transliteration {
    const phonetic_sets = comptime PhoneticSets.init(mode);

    const rules: Grammar = comptime switch (mode) {
        .avro => @import("rules.zon"),
        .orva => @import("orva.zon"),
        .banglish => @import("rules.zon"),
        .lishbang => @import("rules.zon"),
    };

    // For Latin->Bangla (avro) mode, we use ASCII trie
    // For Bangla->Latin (orva) mode, we use Unicode trie
    const trie = if (mode != .orva)
        buildTrie(allocator, rules) catch unreachable
    else
        TrieNode.init(allocator) catch unreachable;

    const unicode_trie = if (mode == .orva)
        buildUnicodeTrie(allocator, rules) catch unreachable
    else
        UnicodeTrieNode.init(allocator) catch unreachable;

    return .{
        .rules = rules,
        .allocator = allocator,
        .phonetic_sets = phonetic_sets,
        .trie = trie,
        .unicode_trie = unicode_trie,
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
    self.unicode_trie.deinit();
    self.allocator.destroy(self.unicode_trie);
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
    var output = std.array_list.Managed(u8).init(self.allocator);
    errdefer output.deinit();
    try output.ensureTotalCapacity(fixed.len * 3); // Pre-allocate with more space for worst case

    const len = fixed.len;
    var currentIndex: usize = 0;

    // Reuse buffer for pattern output to avoid allocation in hot loop
    var result_buffer = std.array_list.Managed(u8).init(self.allocator);
    defer result_buffer.deinit();
    try result_buffer.ensureTotalCapacity(32); // Typical replacement size

    if (self.mode == .orva) {
        // Unicode mode - for Bangla to Latin conversion
        while (currentIndex < len) {
            // Get the next Unicode codepoint and its length
            var utf8_iter = std.unicode.Utf8Iterator{ .bytes = fixed, .i = currentIndex };
            const codepoint_opt = utf8_iter.nextCodepoint();

            if (codepoint_opt == null) break;

            const codepoint = codepoint_opt.?;
            const codepoint_len = utf8_iter.i - currentIndex;

            var node = self.unicode_trie;
            var matchLength: usize = 0;
            var matchPattern: ?*const Grammar.Pattern = null;

            // Check if this codepoint has a match in the trie
            if (node.children.get(codepoint)) |next_node| {
                if (next_node.isEndOfPattern) {
                    matchLength = codepoint_len;
                    matchPattern = next_node.pattern;
                }

                // Continue matching more codepoints if possible
                var i: usize = currentIndex + codepoint_len;
                var current_node = next_node;

                while (i < len) {
                    var inner_iter = std.unicode.Utf8Iterator{ .bytes = fixed, .i = i };
                    const next_codepoint_opt = inner_iter.nextCodepoint();
                    if (next_codepoint_opt == null) break;

                    const next_codepoint = next_codepoint_opt.?;
                    const next_codepoint_len = inner_iter.i - i;

                    const next_unicode_node = current_node.children.get(next_codepoint) orelse break;

                    current_node = next_unicode_node;
                    i += next_codepoint_len;

                    if (current_node.isEndOfPattern) {
                        matchLength = i - currentIndex;
                        matchPattern = current_node.pattern;
                    }
                }
            }

            if (matchPattern) |pattern| {
                const endIndex = currentIndex + matchLength;
                // Clear buffer for reuse
                result_buffer.clearRetainingCapacity();

                const result = try self.processPattern(pattern.*, fixed, currentIndex, endIndex, &result_buffer);
                try output.appendSlice(result.output);
                if (takesInherentVowel(pattern.find, fixed, currentIndex, endIndex)) try output.append('o');
                currentIndex = result.newIndex + 1;
            } else {
                // Just copy the original character
                try output.appendSlice(fixed[currentIndex .. currentIndex + codepoint_len]);
                currentIndex += codepoint_len;
            }
        }

        // Filter out non-ASCII characters in orva mode
        var filtered_output = std.array_list.Managed(u8).init(self.allocator);
        errdefer filtered_output.deinit();
        try filtered_output.ensureTotalCapacity(output.items.len);

        for (output.items) |char| {
            if (char <= 127) { // Only keep ASCII characters
                try filtered_output.append(char);
            }
        }

        output.deinit();
        return filtered_output.toOwnedSlice();
    } else {
        // ASCII mode - original implementation for Latin to Bangla conversion
        while (currentIndex < len) {
            var node = self.trie;
            var matchLength: usize = 0;
            var matchPattern: ?*const Grammar.Pattern = null;
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
    }

    return output.toOwnedSlice();
}

// Using a more efficient character-indexed trie node
const TrieNode = struct {
    // Direct array indexing for ASCII characters (much faster than HashMap)
    children: [256]?*TrieNode,
    pattern: ?*const Grammar.Pattern,
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

// New Unicode trie node using a hash map for children
const UnicodeTrieNode = struct {
    children: std.AutoHashMap(u21, *UnicodeTrieNode),
    pattern: ?*const Grammar.Pattern,
    isEndOfPattern: bool,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !*UnicodeTrieNode {
        const node = try allocator.create(UnicodeTrieNode);

        node.children = std.AutoHashMap(u21, *UnicodeTrieNode).init(allocator);
        node.pattern = null;
        node.isEndOfPattern = false;
        node.allocator = allocator;

        return node;
    }

    fn deinit(self: *UnicodeTrieNode) void {
        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.children.deinit();
    }
};

fn buildTrie(
    allocator: std.mem.Allocator,
    rules: Grammar,
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

fn buildUnicodeTrie(
    allocator: std.mem.Allocator,
    rules: Grammar,
) !*UnicodeTrieNode {
    const root = try UnicodeTrieNode.init(allocator);
    errdefer root.deinit();

    for (rules.patterns) |*pattern| {
        var current = root;
        const find = pattern.find;

        var utf8_iter = std.unicode.Utf8Iterator{ .bytes = find, .i = 0 };

        while (utf8_iter.nextCodepoint()) |codepoint| {
            if (!current.children.contains(codepoint)) {
                const new_node = try UnicodeTrieNode.init(allocator);
                try current.children.put(codepoint, new_node);
            }
            current = current.children.get(codepoint).?;
        }

        current.isEndOfPattern = true;
        current.pattern = pattern;
    }

    return root;
}

fn processPattern(
    self: *Transliteration,
    pattern: Grammar.Pattern,
    chars: []const u8,
    startIndex: usize,
    endIndex: usize,
    result_buffer: *std.array_list.Managed(u8),
) !struct { output: []const u8, newIndex: usize } {
    if (pattern.rules == null) {
        try result_buffer.appendSlice(pattern.replace);
        return .{ .output = result_buffer.items, .newIndex = endIndex - 1 };
    }

    for (pattern.rules.?) |rule| {
        var shouldReplace: bool = true;

        for (rule.matches) |match| {
            const isSuffix = match.type == .suffix;
            // The character next to the match; null at the start/end of input.
            const context = self.contextChar(chars, startIndex, endIndex, isSuffix);
            const isNegative = match.negative;
            const scope = match.scope;

            if (scope) |s| {
                // Handle different scope types using switch statement
                switch (s) {
                    .punctuation => {
                        const hasPunctuation = if (context) |c| self.phonetic_sets.isPunctuation(c) else true;

                        if (hasPunctuation == isNegative) {
                            shouldReplace = false;
                            break;
                        }
                    },
                    .vowel => {
                        const isVowelMatch = if (context) |c| self.phonetic_sets.isVowel(c) else false;

                        if (isVowelMatch == isNegative) {
                            shouldReplace = false;
                            break;
                        }
                    },
                    .consonant => {
                        const isConsonantMatch = if (context) |c| self.phonetic_sets.isConsonant(c) else false;

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

/// Bangla consonants carry an implicit "o" (ক = "ko"). It is written out
/// when the next letter is another consonant or an independent vowel
/// (করি → "kori", বই → "boi"), not before a vowel sign or hasanta, nor at the
/// end of a word (অনেক → "onek").
///
/// Speech also drops it between a vowel and a consonant that carries a vowel
/// sign (V·C·CV: লিখতে → "likhte", বলতে → "bolte"), unless dropping it would
/// merge two letters into another Avro letter (ক + হ → "kh", ন + গ → "ng").
///
/// `find` is the matched Bangla at `chars[start..next]`.
fn takesInherentVowel(find: []const u8, chars: []const u8, start: usize, next: usize) bool {
    const last = lastCodepoint(find) orelse return false;
    if (!isBanglaConsonant(last) or last == 0x09CE) return false; // ৎ has none
    const c = codepointAt(chars, next) orelse return false;
    if (c == 0x0985) return false; // অ spells the "o" itself (ধঅ্য is Avro's "dhoZ")
    if (c >= 0x0986 and c <= 0x0994) return true; // independent vowels আ … ঔ
    if (c == 0x0982 or c == 0x0983) return true; // ং ঃ
    if (!isBanglaConsonant(c)) return false;

    // Conjuncts keep it (চন্দ্র → "chondro", রবীন্দ্রনাথ → "robIndronath").
    if (std.mem.indexOf(u8, find, "\u{09CD}") != null) return true;
    const prev = codepointBefore(chars, start) orelse return true; // word start
    const after_vowel = isVowelSign(prev) or (prev >= 0x0985 and prev <= 0x0994) or isBanglaConsonant(prev);
    if (!after_vowel or !clusterHasVowelSign(chars, next)) return true;
    // Typed together, Avro would join these into a conjunct (জানতে as "jante"
    // gives জান্তে), so the "o" has to stay: "janote".
    if (avroJoins(last, c)) return true;
    if (c == 0x09B9) return true; // হ
    if (c == 0x0997 and (last == 0x09A8 or last == 0x09A3)) return true; // ন/ণ + গ
    return false;
}

/// Consonant pairs (X, Y) for which some Avro output contains X্Y, indexed by
/// their offsets in the Bengali block.
const avro_conjuncts = blk: {
    @setEvalBranchQuota(200_000);
    const avro: Grammar = @import("rules.zon");
    var set = std.StaticBitSet(128 * 128).empty;
    for (avro.patterns) |pattern| {
        markConjuncts(&set, pattern.replace);
        if (pattern.rules) |rules| for (rules) |rule| markConjuncts(&set, rule.replace);
    }
    break :blk set;
};

fn markConjuncts(set: *std.StaticBitSet(128 * 128), bangla: []const u8) void {
    var cps: [64]u21 = undefined;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(bangla) catch unreachable).iterator();
    while (it.nextCodepoint()) |c| : (n += 1) cps[n] = c;
    var i: usize = 0;
    while (i + 2 < n) : (i += 1) {
        if (cps[i + 1] == HASANTA and isBanglaConsonant(cps[i]) and isBanglaConsonant(cps[i + 2]))
            set.set((cps[i] - 0x0980) * 128 + (cps[i + 2] - 0x0980));
    }
}

fn avroJoins(a: u21, b: u21) bool {
    if (a < 0x0980 or a >= 0x0A00 or b < 0x0980 or b >= 0x0A00) return false;
    if (b == 0x09B0) return true; // "r" after any consonant types র-ফলা (্র)
    return avro_conjuncts.isSet((a - 0x0980) * 128 + (b - 0x0980));
}

/// Whether the consonant cluster at `i` (C, C্C, …) is followed by a vowel sign.
fn clusterHasVowelSign(chars: []const u8, start: usize) bool {
    var i = start;
    while (true) {
        const c = codepointAt(chars, i) orelse return false;
        if (!isBanglaConsonant(c)) return false;
        i += std.unicode.utf8CodepointSequenceLength(c) catch return false;
        if (codepointAt(chars, i) == 0x09BC) i += 3; // nukta
        const n = codepointAt(chars, i) orelse return false;
        if (n != HASANTA) return isVowelSign(n);
        i += 3;
    }
}

fn isVowelSign(c: u21) bool {
    return (c >= 0x09BE and c <= 0x09CC) or c == 0x09D7;
}

fn isBanglaConsonant(c: u21) bool {
    return (c >= 0x0995 and c <= 0x09B9) or c == 0x09CE or c == 0x09DC or c == 0x09DD or c == 0x09DF;
}

fn codepointAt(s: []const u8, i: usize) ?u21 {
    if (i >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    return std.unicode.utf8Decode(s[i..][0..len]) catch null;
}

fn codepointBefore(s: []const u8, end: usize) ?u21 {
    if (end == 0) return null;
    var i = end - 1;
    while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    return std.unicode.utf8Decode(s[i..end]) catch null;
}

fn lastCodepoint(s: []const u8) ?u21 {
    return codepointBefore(s, s.len);
}

/// The character a rule inspects: the one before `startIndex` (prefix) or at
/// `endIndex` (suffix), or null at the edge of the input. Orva input is UTF-8
/// Bangla, so this decodes a whole codepoint; the Latin modes are ASCII bytes.
fn contextChar(self: *Transliteration, chars: []const u8, startIndex: usize, endIndex: usize, isSuffix: bool) ?u21 {
    if (isSuffix) {
        if (endIndex >= chars.len) return null;
        if (self.mode != .orva) return chars[endIndex];
        const len = std.unicode.utf8ByteSequenceLength(chars[endIndex]) catch return chars[endIndex];
        if (endIndex + len > chars.len) return null;
        return std.unicode.utf8Decode(chars[endIndex..][0..len]) catch chars[endIndex];
    }
    if (startIndex == 0) return null;
    if (self.mode != .orva) return chars[startIndex - 1];
    var i = startIndex - 1;
    while (i > 0 and chars[i] & 0xC0 == 0x80) i -= 1; // back to the lead byte
    return std.unicode.utf8Decode(chars[i..startIndex]) catch chars[startIndex - 1];
}

fn normalizeInput(self: *Transliteration, input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (self.mode == .orva) {
        // For Orva (Bangla->Latin), no case conversion needed
        return try allocator.dupe(u8, input);
    } else {
        // For other modes (Latin->Bangla), apply case conversion selectively
        var fixed = try allocator.alloc(u8, input.len);
        errdefer allocator.free(fixed);

        for (input, 0..) |char, i| {
            if (self.phonetic_sets.isCaseSensitive(char)) {
                fixed[i] = char;
            } else {
                fixed[i] = std.ascii.toLower(char);
            }
        }
        return fixed;
    }
}

fn isExact(needle: []const u8, heystack: []const u8, start: usize, end: usize, not: bool) bool {
    if (start < 0 or end > heystack.len) {
        return not;
    }

    const substring = heystack[start..end];
    return (std.mem.eql(u8, substring, needle)) != not;
}

// Grammar is the internal representation of the grammar
pub const Grammar = struct {
    pub const RuleMatch = struct {
        pub const Type = enum {
            suffix,
            prefix,
            exact,
        };
        pub const Scope = enum {
            vowel,
            consonant,
            exact,
            punctuation,
        };

        type: Type,
        scope: ?Scope = null,
        negative: bool = false,
        value: ?[]const u8 = null,
    };

    pub const Pattern = struct {
        find: []const u8,
        replace: []const u8,
        rules: ?[]const Grammar.Rule = null,
    };

    pub const Rule = struct {
        matches: []const RuleMatch,
        replace: []const u8,
    };

    vowel: []const u8, // Full Unicode range
    consonant: []const u8, // Full Unicode range
    casesensitive: []const u8, // Full Unicode range
    patterns: []const Pattern,
};

// ------------ TESTING ------------
const expect = std.testing.expect;
const assert = std.debug.assert;
const testing = std.testing;

// Helper function to load test data
fn loadTestData(allocator: std.mem.Allocator) !struct { avro_tests: []const std.json.Value, ligature_tests: std.json.ObjectMap, parsed: std.json.Parsed(std.json.Value) } {
    const file_content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/assets/transliteration.test.json", allocator, .unlimited);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_content, .{});
    errdefer parsed.deinit();

    const avro_tests = parsed.value.object.get("samples").?.array.items;
    const ligature_tests = parsed.value.object.get("ligature").?.object;

    return .{ .avro_tests = avro_tests, .ligature_tests = ligature_tests, .parsed = parsed };
}

// test "mode: debug test" {
//     const allocator = std.heap.page_allocator;
//     var transliteratior = Transliteration.init(allocator, .orva);
//     defer transliteratior.deinit();

//     const result = transliteratior.transliterate("কেমন");
//     const expected = "kemon";
//     defer allocator.free(result);
//     // std.debug.print("\n\nExpect: {s}\nGot:    {s}\n", .{ expected, result });
//     try testing.expectEqualStrings(result, expected);
// }

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

// Orva's contract: Latin that types the same Bangla back in Avro. The samples'
// hand-written Latin is one of several valid spellings (golp / golpo), so the
// paragraphs are checked by round trip; `mode: orva debug test` pins exact
// output for unambiguous words.
test "mode: orva test cases" {
    const allocator = std.heap.page_allocator;
    const test_data = try loadTestData(allocator);
    defer test_data.parsed.deinit();

    var orva = Transliteration.init(allocator, .orva);
    defer orva.deinit();
    var avro = Transliteration.init(allocator, .avro);
    defer avro.deinit();

    for (test_data.avro_tests) |test_case| {
        const bn = test_case.object.get("bn").?.string;

        const latin = orva.transliterate(bn);
        defer allocator.free(latin);
        const back = avro.transliterate(latin);
        defer allocator.free(back);

        try testing.expectEqualStrings(bn, back);
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
    var large_text = std.array_list.Managed(u8).init(allocator);
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
        const start_time = std.Io.Timestamp.now(std.testing.io, .awake);
        const result = transliteratior.transliterate(large_text.items);
        defer allocator.free(result);
        const end_time = std.Io.Timestamp.now(std.testing.io, .awake);

        const execution_time = @as(f64, @floatFromInt(end_time.nanoseconds - start_time.nanoseconds)) / 1_000_000.0; // Convert to milliseconds
        total_time += execution_time;

        // Verify the result is correct (check first few characters)
        const expected_prefix = first_avro.object.get("bn").?.string;
        try expect(std.mem.startsWith(u8, result, expected_prefix));
    }

    const avg_execution_time = total_time / @as(f64, @floatFromInt(NUM_RUNS));
    const avg_execution_time_per_thousand_chars = (avg_execution_time / @as(f64, @floatFromInt(large_text.items.len))) * 1000.0;

    // The function should process large text in reasonable time. Unoptimized
    // builds run about 10x slower, so they get a proportionally larger budget.
    const ALLOWED_TIME_PER_THOUSAND_CHARS: f64 = if (@import("builtin").mode == .debug) 2.0 else 0.2;
    std.debug.print("\nAverage Time Taken per 1000 chars: {d:.2}ms\n", .{avg_execution_time_per_thousand_chars});
    try expect(avg_execution_time_per_thousand_chars < ALLOWED_TIME_PER_THOUSAND_CHARS);
}

test "mode: orva debug test" {
    const allocator = std.heap.page_allocator;
    var transliterator = Transliteration.init(allocator, .orva);
    defer transliterator.deinit();

    const test_cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "কেমন", .expected = "kemon" },
        .{ .input = "আমার", .expected = "amar" },
        .{ .input = "বাংলা", .expected = "bangla" },
        .{ .input = "করি", .expected = "kori" }, // inherent "o" between consonants
        .{ .input = "অনেক", .expected = "onek" }, // none at the end of a word
        .{ .input = "বন্ধু", .expected = "bondhu" },
        .{ .input = "লিখতে", .expected = "likhte" }, // dropped as in speech
        .{ .input = "জানতে", .expected = "janote" }, // kept: Avro "nt" would be ন্ত
        .{ .input = "সাধনা", .expected = "sadhona" }, // kept: Avro "dhn" would be ধ্ন
        .{ .input = "রবীন্দ্রনাথ", .expected = "robIndronath" }, // kept after a conjunct
        .{ .input = "বিশ্বে", .expected = "bishwe" }, // ব-ফলা
        .{ .input = "মধ্যে", .expected = "modhZe" }, // য-ফলা
        .{ .input = "অর্জন", .expected = "orrjon" }, // রেফ
    };

    for (test_cases) |tc| {
        const result = transliterator.transliterate(tc.input);
        defer allocator.free(result);

        try testing.expectEqualStrings(tc.expected, result);
    }
}
