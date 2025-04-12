const std = @import("std");

pub const TokenKind = enum {
    document,
    paragraph,
    sentence,
    word, // Bengali words
    symbol, // Punctuation, currency signs etc.
    digit, // Bengali digits
    foreign, // Non-Bengali characters/words
    whitespace, // Added temporarily for logic, might remove later
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const WordNode = struct {
    kind: TokenKind,
    value: []const u8,
};

pub const SentenceNode = struct {
    kind: TokenKind,
    value: []const u8,
    tokens: []WordNode,
};

pub const ParagraphNode = struct {
    kind: TokenKind,
    value: []const u8,
    tokens: []SentenceNode,
};

pub const DocumentNode = struct {
    kind: TokenKind,
    value: []const u8,
    tokens: []ParagraphNode,
};

pub const TokenizerError = error{
    UnexpectedEndOfInput,
    UnexpectedToken,
    EmptySentence,
} || std.mem.Allocator.Error;

pub const PrintFormat = enum {
    json,
    readable,
};

const DelimiterType = enum {
    single_byte, // For ASCII characters like ? !
    multi_byte, // For UTF-8 characters like Bengali Danda
};

const Delimiter = union(DelimiterType) {
    single_byte: u8,
    multi_byte: struct {
        bytes: [3]u8,
        len: usize,
    },
};

const Range = struct {
    start: u21,
    end: u21,
};

const Spec = struct {
    kind: TokenKind,
    ranges: []const Range,
    delimiters: []const Delimiter,
    is_delimiter: bool = false,
};

const SPECS = [_]Spec{
    // Word spec (Bengali characters)
    .{
        .kind = .word,
        .ranges = &[_]Range{
            .{ .start = 0x0981, .end = 0x0983 }, // Candrabindu, Anusvara, Visarga
            .{ .start = 0x0985, .end = 0x098C }, // Vowels A-L
            .{ .start = 0x098F, .end = 0x0990 }, // Vowels E, AI
            .{ .start = 0x0993, .end = 0x09AE }, // Vowels O, AU, Consonants Ka-Ma
            .{ .start = 0x09AF, .end = 0x09B0 }, // Consonants Ya, Ra
            .{ .start = 0x09B2, .end = 0x09B2 }, // Consonant La
            .{ .start = 0x09B6, .end = 0x09B9 }, // Consonants Sha-Ha
            .{ .start = 0x09BC, .end = 0x09C4 }, // Signs Nukta, Avagraha, Vowel Signs AA-VOCALIC_RR
            .{ .start = 0x09C7, .end = 0x09C8 }, // Vowel Signs E, AI
            .{ .start = 0x09CB, .end = 0x09CE }, // Vowel Signs O, AU, Virama, Khanda Ta
            .{ .start = 0x09D7, .end = 0x09D7 }, // AU Length Mark
            .{ .start = 0x09DC, .end = 0x09DD }, // Letters RRA, RHA
            .{ .start = 0x09DF, .end = 0x09E3 }, // Letter YYA, Vocalic RR, LL, Vowel Signs VOCALIC L, LL
            .{ .start = 0x09FA, .end = 0x09FB }, // Isshar, Ganda Mark
            .{ .start = 0x09FE, .end = 0x09FE }, // Sandhi Mark
        },
        .delimiters = &[_]Delimiter{},
    },
    // Digit spec (Bengali digits)
    .{
        .kind = .digit,
        .ranges = &[_]Range{
            .{ .start = 0x09E6, .end = 0x09EF },
        },
        .delimiters = &[_]Delimiter{},
    },
    // Symbol spec
    .{
        .kind = .symbol,
        .ranges = &[_]Range{
            .{ .start = 0x09F2, .end = 0x09F9 }, // Bengali Currency Symbols
            .{ .start = 0x09FD, .end = 0x09FD }, // Abbreviation Sign
        },
        .delimiters = &[_]Delimiter{
            .{ .single_byte = '(' },
            .{ .single_byte = ')' },
            .{ .single_byte = ',' },
            .{ .single_byte = ';' },
            .{ .single_byte = ':' },
            .{ .single_byte = '"' },
            .{ .single_byte = '\'' },
            .{ .single_byte = '[' },
            .{ .single_byte = ']' },
            .{ .single_byte = '{' },
            .{ .single_byte = '}' },
            .{ .single_byte = '/' },
            .{ .single_byte = '\\' },
            .{ .single_byte = '-' },
            .{ .single_byte = '+' },
            .{ .single_byte = '=' },
            .{ .single_byte = '*' },
            .{ .single_byte = '&' },
            .{ .single_byte = '^' },
            .{ .single_byte = '%' },
            .{ .single_byte = '$' },
            .{ .single_byte = '#' },
            .{ .single_byte = '@' },
            .{ .single_byte = '`' },
            .{ .single_byte = '~' },
        },
    },
    // Sentence delimiter spec
    .{
        .kind = .symbol,
        .ranges = &[_]Range{},
        .delimiters = &[_]Delimiter{
            .{ .multi_byte = .{ .bytes = .{ 0xE0, 0xA5, 0xA4 }, .len = 3 } }, // Bengali Danda (।)
            .{ .single_byte = '?' },
            .{ .single_byte = '!' },
        },
        .is_delimiter = true,
    },
    // Whitespace spec
    .{
        .kind = .whitespace,
        .ranges = &[_]Range{},
        .delimiters = &[_]Delimiter{
            .{ .single_byte = ' ' },
            .{ .single_byte = '\t' },
            .{ .single_byte = '\r' },
            .{ .single_byte = '\n' },
        },
    },
};

pub const Tokenizer = struct {
    input: []const u8,
    position: usize = 0,
    current_token: ?Token = null,
    allocator: std.mem.Allocator,
    ast: ?DocumentNode = null,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Tokenizer {
        return Tokenizer{
            .input = input,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        if (self.ast) |ast| {
            freeAST(ast, self.allocator);
            self.ast = null;
        }
    }

    fn getCharKindFromSpecs(codepoint: u21) TokenKind {
        for (SPECS) |spec| {
            for (spec.ranges) |range| {
                if (codepoint >= range.start and codepoint <= range.end) {
                    return spec.kind;
                }
            }
            for (spec.delimiters) |delimiter| {
                switch (delimiter) {
                    .single_byte => |byte| {
                        if (codepoint == byte) return spec.kind;
                    },
                    .multi_byte => {
                        // Skip multi-byte checks here as they need the full byte sequence
                        continue;
                    },
                }
            }
        }
        return .foreign;
    }

    fn isDelimiter(token: Token) bool {
        const spec = blk: {
            for (SPECS) |s| {
                if (s.is_delimiter) {
                    // Check if token matches any delimiter in this spec
                    for (s.delimiters) |delimiter| {
                        switch (delimiter) {
                            .single_byte => |byte| {
                                if (token.value.len == 1 and token.value[0] == byte) {
                                    break :blk true;
                                }
                            },
                            .multi_byte => |mb| {
                                if (token.value.len == mb.len) {
                                    var matches = true;
                                    for (mb.bytes[0..mb.len], 0..) |byte, i| {
                                        if (token.value[i] != byte) {
                                            matches = false;
                                            break;
                                        }
                                    }
                                    if (matches) break :blk true;
                                }
                            },
                        }
                    }
                }
            }
            break :blk false;
        };
        return spec;
    }

    pub fn parse(self: *Tokenizer) !DocumentNode {
        // Reset position and current token
        self.position = 0;
        self.current_token = null;

        // Free previous AST if it exists
        if (self.ast) |ast| {
            freeAST(ast, self.allocator);
        }

        var para_list = std.ArrayList(ParagraphNode).init(self.allocator);
        defer para_list.deinit();

        // Split input into paragraphs by newlines
        var para_iter = std.mem.splitScalar(u8, self.input, '\n');
        var para_start: usize = 0;

        while (para_iter.next()) |para_text| {
            if (std.mem.trim(u8, para_text, " \t\r").len == 0) {
                para_start += para_text.len + 1;
                continue;
            }

            // Get the first token for this paragraph
            self.position = para_start;
            self.current_token = try self.nextInternal();

            const para = try self.parseParagraph(para_start, para_start + para_text.len);
            if (para) |p| {
                try para_list.append(p);
            }

            para_start += para_text.len + 1;
        }

        // Create the document node
        const paragraphs_slice = try para_list.toOwnedSlice();
        self.ast = DocumentNode{
            .kind = .document,
            .value = self.input,
            .tokens = paragraphs_slice,
        };

        // Reset position and get first token for token-by-token processing
        self.position = 0;
        self.current_token = try self.nextInternal();

        return self.ast.?;
    }

    pub fn getWords(self: *Tokenizer) ![]const []const u8 {
        if (self.ast == null) {
            _ = try self.parse();
        }

        var words = std.ArrayList([]const u8).init(self.allocator);
        defer words.deinit();

        for (self.ast.?.tokens) |para| {
            for (para.tokens) |sent| {
                for (sent.tokens) |token| {
                    if (token.kind == .word) {
                        try words.append(token.value);
                    }
                }
            }
        }

        return words.toOwnedSlice();
    }

    pub fn print(self: *Tokenizer, format: PrintFormat) ![]const u8 {
        if (self.ast == null) {
            _ = try self.parse();
        }

        switch (format) {
            .readable => {
                return printReadable(self.ast.?, self.allocator);
            },
            .json => {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                errdefer arena.deinit();

                var json_str = std.ArrayList(u8).init(arena.allocator());
                try std.json.stringify(self.ast.?, .{ .whitespace = .indent_2 }, json_str.writer());

                // Copy to output buffer
                const result = try self.allocator.dupe(u8, json_str.items);
                arena.deinit();
                return result;
            },
        }
    }

    fn printReadable(doc: DocumentNode, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        try output.writer().writeAll("--- AST Structure ---\n");

        // Helper function to validate and format UTF-8 text
        const formatText = struct {
            fn format(text: []const u8) []const u8 {
                return if (std.unicode.utf8ValidateSlice(text)) text else "(Invalid UTF-8)";
            }
        }.format;

        // Print paragraphs
        for (doc.tokens, 0..) |para, i| {
            try std.fmt.format(output.writer(), "{s}Paragraph {d} (Len: {d}): {s}\n", .{
                "    " ** 0,
                i,
                para.value.len,
                formatText(para.value),
            });

            // Print sentences
            for (para.tokens, 0..) |sent, j| {
                try std.fmt.format(output.writer(), "{s}Sentence {d} (Len: {d}): {s}\n", .{
                    "    " ** 1,
                    j,
                    sent.value.len,
                    formatText(sent.value),
                });

                // Print tokens
                for (sent.tokens, 0..) |node, k| {
                    if (node.value.len == 0) {
                        try std.fmt.format(output.writer(), "{s}{s} {d}: (Empty String)\n", .{
                            "    " ** 2,
                            @tagName(node.kind),
                            k,
                        });
                    } else {
                        try std.fmt.format(output.writer(), "{s}{s} {d} (Len: {d}): {s}\n", .{
                            "    " ** 2,
                            @tagName(node.kind),
                            k,
                            node.value.len,
                            formatText(node.value),
                        });
                    }
                }
            }
        }

        return output.toOwnedSlice();
    }

    fn printJSON(doc: DocumentNode, allocator: std.mem.Allocator) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var json_str = std.ArrayList(u8).init(arena.allocator());
        try std.json.stringify(doc, .{ .whitespace = .indent_2 }, json_str.writer());
        return json_str.toOwnedSlice();
    }

    pub fn next(self: *Tokenizer) !?Token {
        const current = self.current_token;
        self.current_token = try self.nextInternal();
        return current;
    }

    fn nextInternal(self: *Tokenizer) !?Token {
        // Skip whitespace
        while (self.position < self.input.len) {
            var iter = std.unicode.Utf8Iterator{ .bytes = self.input, .i = self.position };
            const codepoint_slice = iter.nextCodepointSlice() orelse break;
            const codepoint = std.unicode.utf8Decode(codepoint_slice) catch |err| {
                std.debug.print("Warning: UTF-8 decode error in tokenizer: {any}\n", .{err});
                self.position += codepoint_slice.len;
                continue;
            };

            if (getCharKindFromSpecs(codepoint) != .whitespace) {
                break;
            }
            self.position += codepoint_slice.len;
        }

        if (self.position >= self.input.len) {
            return null;
        }

        const start_pos = self.position;

        // First, check for multi-byte delimiters
        for (SPECS) |spec| {
            for (spec.delimiters) |delimiter| {
                switch (delimiter) {
                    .multi_byte => |mb| {
                        if (self.position + mb.len <= self.input.len) {
                            var matches = true;
                            for (mb.bytes[0..mb.len], 0..) |byte, i| {
                                if (self.input[self.position + i] != byte) {
                                    matches = false;
                                    break;
                                }
                            }
                            if (matches) {
                                self.position += mb.len;
                                return Token{
                                    .kind = spec.kind,
                                    .value = self.input[start_pos..self.position],
                                };
                            }
                        }
                    },
                    .single_byte => continue,
                }
            }
        }

        // Then proceed with regular tokenization
        var iter = std.unicode.Utf8Iterator{ .bytes = self.input, .i = self.position };
        const first_codepoint_slice = iter.nextCodepointSlice() orelse return null;
        const first_codepoint = std.unicode.utf8Decode(first_codepoint_slice) catch |err| {
            std.debug.print("Warning: UTF-8 decode error in tokenizer: {any}\n", .{err});
            self.position += first_codepoint_slice.len;
            return Token{
                .kind = .foreign,
                .value = first_codepoint_slice,
            };
        };

        const kind = getCharKindFromSpecs(first_codepoint);
        var end_pos = start_pos + first_codepoint_slice.len;

        // For symbols, we only take one character
        if (kind == .symbol) {
            self.position = end_pos;
            return Token{
                .kind = kind,
                .value = self.input[start_pos..end_pos],
            };
        }

        // For other kinds, we collect all consecutive characters of the same kind
        while (end_pos < self.input.len) {
            var next_iter = std.unicode.Utf8Iterator{ .bytes = self.input, .i = end_pos };
            const next_slice = next_iter.nextCodepointSlice() orelse break;
            const next_codepoint = std.unicode.utf8Decode(next_slice) catch break;
            const next_kind = getCharKindFromSpecs(next_codepoint);

            if (next_kind == kind) {
                end_pos += next_slice.len;
            } else {
                break;
            }
        }

        self.position = end_pos;
        return Token{
            .kind = kind,
            .value = self.input[start_pos..end_pos],
        };
    }

    pub fn eat(self: *Tokenizer, expected_kind: TokenKind) !Token {
        if (self.current_token) |token| {
            if (token.kind == expected_kind) {
                // Consume the current token and get the next one
                self.current_token = try self.nextInternal();
                return token;
            } else {
                return TokenizerError.UnexpectedToken;
            }
        }
        return TokenizerError.UnexpectedEndOfInput;
    }

    pub fn peek(self: *Tokenizer) ?Token {
        return self.current_token;
    }

    fn parseParagraph(self: *Tokenizer, start: usize, end: usize) !?ParagraphNode {
        var sentence_list = std.ArrayList(SentenceNode).init(self.allocator);
        var para_success = false;
        defer if (!para_success) sentence_list.deinit();

        // Process sentences
        while (self.position < end) {
            const sentence = try self.parseSentence();
            if (sentence) |s| {
                try sentence_list.append(s);
            }

            // Skip whitespace between sentences
            while (self.peek()) |token| {
                if (token.kind == .whitespace and self.position < end) {
                    _ = try self.next();
                } else break;
            }
        }

        // If no sentences were parsed, return null
        if (sentence_list.items.len == 0) return null;

        // Create the paragraph node
        const sentences_slice = try sentence_list.toOwnedSlice();
        para_success = true;

        return ParagraphNode{
            .kind = .paragraph,
            .value = self.input[start..end],
            .tokens = sentences_slice,
        };
    }

    fn parseSentence(self: *Tokenizer) !?SentenceNode {
        var word_list = std.ArrayList(WordNode).init(self.allocator);
        var sent_start = self.position;
        var sent_success = false;
        defer if (!sent_success) word_list.deinit();

        // Skip leading whitespace
        while (self.peek()) |token| {
            if (token.kind == .whitespace) {
                _ = try self.next();
                sent_start = self.position;
            } else break;
        }

        // Check if we're at the end
        if (self.peek() == null) return null;

        // Process words until we hit a sentence delimiter or end of input
        var had_content = false;
        while (self.peek()) |token| {
            if (isDelimiter(token)) {
                if (had_content) {
                    _ = try self.next(); // consume the delimiter
                    break;
                }
            }

            switch (token.kind) {
                .word, .digit, .foreign => {
                    had_content = true;
                    _ = try self.next();
                    try word_list.append(WordNode{
                        .kind = token.kind,
                        .value = token.value,
                    });
                },
                .symbol => {
                    had_content = true;
                    _ = try self.next();
                    try word_list.append(WordNode{
                        .kind = token.kind,
                        .value = token.value,
                    });
                },
                .whitespace => {
                    _ = try self.next(); // skip whitespace
                },
                else => break,
            }
        }

        // If no words were parsed, return null
        if (word_list.items.len == 0) return null;

        // Create the sentence node
        const words_slice = try word_list.toOwnedSlice();
        sent_success = true;

        return SentenceNode{
            .kind = .sentence,
            .value = self.input[sent_start..self.position],
            .tokens = words_slice,
        };
    }
};

fn freeAST(doc: DocumentNode, allocator: std.mem.Allocator) void {
    for (doc.tokens) |para| {
        for (para.tokens) |sent| {
            allocator.free(sent.tokens);
        }
        allocator.free(para.tokens);
    }
    allocator.free(doc.tokens);
}

test "tokenizer parse and print" {
    const allocator = std.testing.allocator;
    const text =
        \\আমি ভাত খাই। তুমি কী করো?
        \\সে স্কুলে যায়!
    ;

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();

    const ast = try tokenizer.parse();

    // Test printing in both formats
    const readable = try tokenizer.print(.readable);
    defer allocator.free(readable);

    const json = try tokenizer.print(.json);
    defer allocator.free(json);

    std.debug.print("Readable: {s}\n", .{readable});
    std.debug.print("JSON: {s}\n", .{json});

    // Verify AST structure
    try std.testing.expectEqual(@as(usize, 2), ast.tokens.len);
    try std.testing.expectEqual(@as(usize, 2), ast.tokens[0].tokens.len);
    try std.testing.expectEqual(@as(usize, 1), ast.tokens[1].tokens.len);
}

test "tokenizer parse and print wiki" {
    const allocator = std.testing.allocator;
    const text = "<div style=\"width:{{{width|100%}}}\"><div style=\"height:8px;border:1px solid #8898BF;-moz-border-radius-topright:8px;-moz-border-radius-topleft:8px;-webkit-border-top-left-radius: 8px; -webkit-border-top-right-radius: 8px; background:#C8D8FF;font-size:1px;\"></div> <div style=\"font-size:small;margin-bottom:1.5em;border:1px solid #8898BF;border-top:0;background:white;padding:5px;\"> <center><big>উইকিপিডিয়াতে [[উইকিপিডিয়া:স্বাগতম, নবাগত|স্বাগতম]] '''$1'''!</big></center> {| |--- |[[File:Wiki letter w.svg]] |উইকিপিডিয়া একটি উন্মুক্ত ইন্টারনেট বিশ্বকোষ যা এর বহু পাঠকদের দ্বারা সম্মিলিতভাবে লিখিত বিশ্বকোষ। এর আকার এতো বড় যে সহজেই আপনি তাতে হারিয়ে যেতে পারেন, তাই এখানে কিছু পাতা রয়েছে যা এর ব্যবহারে আপনাকে সহযোগিতা করবে। উইকিপিডিয়া সম্পর্কে জানতে, দেখুন [[Help:Contents|আমাদের সহায়তা পাতার নির্ঘণ্ট]]। স্বনির্বাচিত অবয়ব এবং অন্যান্য অপশন পেতে, [[Special:Preferences|আমার পছন্দে]] পরিবর্তন করুন। আরও তথ্যের জন্য, [[উইকিপিডিয়া:প্রায়শ জিজ্ঞাসিত প্রশ্ন|প্রায়শ জিজ্ঞাসিত প্রশ্ন (FAQ)]] দেখুন। যদি আপনি কোনো পরিক্ষা নিরীক্ষা করতে চান , দয়া করে [[Wikipedia:Sandbox|খেলাঘর]] ব্যবহার করুন। আপনি মনে করলে নতুন নিবন্ধ অন্তর্ভুক্তির জন্য [[Wikipedia:Article wizard 2.0|নিবন্ধ উইজার্ড]] ব্যবহার করতে পারেন। |--- |[[File:Crystal Clear app ktip.png|left|40px]] |অনুগ্রহপূর্বক আলাপের পাতায় বার্তা রাখার পর [[চিত্র:Insert-signature.png|link=]] চিহ্নে ক্লিক করুন অথবা চারটি টিল্ডা (<nowiki>~~~~</nowiki>) চিহ্ন দিয়ে আপনার স্বাক্ষর করুন; এটি স্বয়ংক্রিয় ভাবে আপনার নাম এবং তারিখ যোগ করবে,কিন্তু কোনো বিশ্বকোষীয় নিবন্ধে এই স্বাক্ষর যোগ করবেন না। [[Wikipedia:Policies and guidelines|আমাদের নীতিমালাগুলো]] জানার আগেই আপনাকে উইকিপিডিয়ায় সম্পাদনা করতে স্বাগতম জানাই। তবে অনুগ্রহ করে, [[Wikipedia:Neutral point of view|নিরপেক্ষতা]] বজায় রাখুন, আপনার নিবন্ধকে [[Wikipedia:Verifiability|যাচাইযোগ্য]] করতে [[Wikipedia:Citing sources|তথ্যসূত্রের উল্লেখ করুন]], এবং মনে রাখবেন আমরা একটি বিশ্বকোষ। [[Wikipedia:Notability| যদি অন্যকেউ কোন বিষয়ে এরই মধ্যে নিবন্ধ শুরু না করেন]], তাহলে হয়তো আমাদেরও শুরু করা উচিত হবে না। |-- |[[File:Crystal Clear app lphoto.png|left|40px]] |আমাদের অনেক নিবন্ধ রয়েছে যেখানে এখনও অনেক ছবির প্রয়োজন, [[:en:Wikipedia:Picture tutorial|উইকিপিডিয়া:ছবি টিউটোরিয়াল]] আপনাকে ছবি যোগ করতে বা আমাদের একজন ফটোগ্রাফার হতে সহায়তা করবে। |-- |[[File:Crystal Clear app amor.png|left|40px]] |আপনার মনে কোনো প্রশ্ন থাকলে আপনি আমাদের তা [[Wikipedia:Questions|সাহায্য কেন্দ্রে]] জানাতে কোনো ইতস্তত বোধ করবেন না। আপনাকে যে কোনো প্রকার প্রশ্ন করার জন্য সেখানে আহবান জানানো হচ্ছে। |--- |[[File:Crystal Clear app help index.png|left|40px]] |আপনার যদি তাও কোনো সাহায্যের প্রয়োজন হয় তবে অনুগ্রহ করে [[Special:Mytalk|আপনার আলাপের পাতার]] শেষে '''{{t1|সাহায্য করুন}}''' কথাটি লিখুন এবং নিচে আপনার প্রশ্ন লিখুন। একজন সাহায্যকারী কিছুক্ষণের মধ্যে আপনার প্রশ্নের উত্তর দেবেন। |} </div> <div style=\"clear:right;padding-top:1em\"></div> <div style=\"background-color:#ff9;border:1px solid #fc0;padding:.3em;font-size:140%;text-align:center;\"> [[উইকিপিডিয়া:ভূমিকা|'''উইকিপিডিয়ার ভূমিকাতে যান এবং উইকিপিডিয়া সম্পর্কে প্রাথমিক জ্ঞান আহরণ করুন''']]</div> </div>";

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();

    _ = try tokenizer.parse();

    // Test printing in both formats
    const readable = try tokenizer.print(.readable);
    defer allocator.free(readable);

    const json = try tokenizer.print(.json);
    defer allocator.free(json);

    const words = try tokenizer.getWords();
    defer allocator.free(words);
    const len = words.len;
    try std.testing.expectEqual(269, len);
}

test "tokenizer basic functionality" {
    const allocator = std.testing.allocator;
    const text = "আমি ভাত খাই।";

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();
    _ = try tokenizer.parse();

    // Test first token
    const first = try tokenizer.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(TokenKind.word, first.?.kind);
    try std.testing.expectEqualStrings("আমি", first.?.value);

    // Test second token
    const second = try tokenizer.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(TokenKind.word, second.?.kind);
    try std.testing.expectEqualStrings("ভাত", second.?.value);

    // Test third token
    const third = try tokenizer.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqual(TokenKind.word, third.?.kind);
    try std.testing.expectEqualStrings("খাই", third.?.value);

    // Test symbol token
    const symbol = try tokenizer.next();
    try std.testing.expect(symbol != null);
    try std.testing.expectEqual(TokenKind.symbol, symbol.?.kind);
    try std.testing.expectEqualStrings("।", symbol.?.value);

    // Test end of input
    const end = try tokenizer.next();
    try std.testing.expect(end == null);
}

test "tokenizer handles mixed content" {
    const allocator = std.testing.allocator;
    const text = "আমি ১২৩ খাই!";

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();
    _ = try tokenizer.parse();

    // Test Word token
    const word_token = try tokenizer.eat(.word);
    try std.testing.expectEqualStrings("আমি", word_token.value);

    // Test Digit token
    const digit_token = try tokenizer.eat(.digit);
    try std.testing.expectEqualStrings("১২৩", digit_token.value);

    // Test Word token
    const word_token2 = try tokenizer.eat(.word);
    try std.testing.expectEqualStrings("খাই", word_token2.value);

    // Test Symbol token
    const symbol_token = try tokenizer.eat(.symbol);
    try std.testing.expectEqualStrings("!", symbol_token.value);

    // Test end of input
    try std.testing.expectError(error.UnexpectedEndOfInput, tokenizer.eat(.word));
}

test "tokenizer handles whitespace correctly" {
    const allocator = std.testing.allocator;
    const text = "  আমি  \t  ভাত  \n  খাই  ";

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();
    _ = try tokenizer.parse();

    // Should skip initial whitespace and get first word
    const first = try tokenizer.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(TokenKind.word, first.?.kind);
    try std.testing.expectEqualStrings("আমি", first.?.value);

    // Should skip whitespace and tab, get second word
    const second = try tokenizer.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(TokenKind.word, second.?.kind);
    try std.testing.expectEqualStrings("ভাত", second.?.value);

    // Should skip whitespace and newline, get third word
    const third = try tokenizer.next();
    try std.testing.expect(third != null);
    try std.testing.expectEqual(TokenKind.word, third.?.kind);
    try std.testing.expectEqualStrings("খাই", third.?.value);

    // Should reach end after skipping trailing whitespace
    const end = try tokenizer.next();
    try std.testing.expect(end == null);
}

test "tokenizer peek method" {
    const allocator = std.testing.allocator;
    const text = "আমি ভাত";

    var tokenizer = Tokenizer.init(text, allocator);
    defer tokenizer.deinit();
    _ = try tokenizer.parse();

    // First peek should show first token
    const first_peek = tokenizer.peek();
    try std.testing.expect(first_peek != null);
    try std.testing.expectEqual(TokenKind.word, first_peek.?.kind);
    try std.testing.expectEqualStrings("আমি", first_peek.?.value);

    // After next(), peek should show second token
    _ = try tokenizer.next();
    const second_peek = tokenizer.peek();
    try std.testing.expect(second_peek != null);
    try std.testing.expectEqual(TokenKind.word, second_peek.?.kind);
    try std.testing.expectEqualStrings("ভাত", second_peek.?.value);
}
