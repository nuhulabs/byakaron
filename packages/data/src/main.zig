const std = @import("std");
const Io = std.Io;
const log = std.log;
const xml = @import("xml");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.InvalidArguments; // usage: data <wiki.xml>

    var input_file = try Io.Dir.cwd().openFile(io, args[1], .{});
    defer input_file.close(io);
    var input_buf: [64 * 1024]u8 = undefined;
    var input_reader = input_file.reader(io, &input_buf);

    // Total file size is used to render progress without ever loading the whole
    // document into memory (we stream it node-by-node below).
    const total_size: u64 = input_reader.getSize() catch 0;

    var streaming_reader: xml.Reader.Streaming = .init(gpa, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var out_file = try Io.Dir.cwd().createFile(io, "sentences.csv", .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;
    try out.writeAll("page_id,rev_id,value\n");

    // Everything allocated while processing a single page lives in this arena
    // and is reset (not freed) when the next page starts, keeping memory flat.
    var page_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer page_arena_state.deinit();

    var in_page = false;
    var in_revision = false;
    var in_contributor = false;
    var page_id: ?[]const u8 = null;
    var rev_id: ?[]const u8 = null;
    var title: []const u8 = "";

    var page_count: usize = 0;
    var sentence_count: usize = 0;
    var last_report_pages: usize = 0;

    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                log.err("{}:{}: {}", .{ loc.line, loc.column, reader.errorCode() });
                return error.MalformedXml;
            },
            else => |other| return other,
        };
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "page")) {
                    _ = page_arena_state.reset(.retain_capacity);
                    in_page = true;
                    in_revision = false;
                    in_contributor = false;
                    page_id = null;
                    rev_id = null;
                    title = "";
                } else if (std.mem.eql(u8, name, "revision")) {
                    in_revision = true;
                    in_contributor = false;
                } else if (std.mem.eql(u8, name, "contributor")) {
                    in_contributor = true;
                } else if (std.mem.eql(u8, name, "title") and in_page and !in_revision) {
                    title = try page_arena_state.allocator().dupe(u8, try reader.readElementText());
                } else if (std.mem.eql(u8, name, "id")) {
                    const value = try reader.readElementText();
                    // <id> appears in three places: page, revision and
                    // contributor. We only care about the first two.
                    if (in_contributor) {
                        // ignore contributor id
                    } else if (in_revision) {
                        rev_id = try page_arena_state.allocator().dupe(u8, value);
                    } else if (in_page) {
                        page_id = try page_arena_state.allocator().dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, name, "text") and in_revision) {
                    // The wikitext body. By the time we reach it the page id and
                    // revision id have already been read (they precede <text>).
                    const wikitext = try reader.readElementText();
                    if (page_id) |pid| {
                        if (rev_id) |rid| {
                            const pa = page_arena_state.allocator();
                            const plain = try normalizeWikiMedia(pa, wikitext);
                            sentence_count += try writeSentences(pa, out, pid, rid, plain);
                        }
                    }
                }
            },
            .element_end => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "contributor")) {
                    in_contributor = false;
                } else if (std.mem.eql(u8, name, "revision")) {
                    in_revision = false;
                } else if (std.mem.eql(u8, name, "page")) {
                    in_page = false;
                    page_count += 1;
                    if (page_count - last_report_pages >= 64) {
                        last_report_pages = page_count;
                        reportProgress(input_reader.pos, total_size, page_count, sentence_count, title);
                    }
                }
            },
            else => {},
        }
    }

    try out.flush();
    reportProgress(input_reader.pos, total_size, page_count, sentence_count, title);
    std.debug.print("\nDone. {d} pages, {d} sentences -> sentences.csv\n", .{ page_count, sentence_count });
}

/// Splits `text` into clean Bangla sentences and appends one CSV row per
/// sentence. Returns the number of rows written.
fn writeSentences(
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    page_id: []const u8,
    rev_id: []const u8,
    text: []const u8,
) !usize {
    var sentences: std.array_list.Managed([]const u8) = .init(allocator);
    defer sentences.deinit();

    try collectSentences(allocator, text, &sentences);

    for (sentences.items) |value| {
        try writeCsvRow(out, page_id, rev_id, value);
    }
    return sentences.items.len;
}

/// Walks `text` accumulating sentences, breaking on sentence delimiters
/// (`।`, `॥`, `?`, `!`, `:`, `,`) and on newlines. Parenthesised spans are
/// pulled out and processed recursively as their own sentences (and removed
/// from the surrounding text). Only sentences that pass `isCleanBangla` are
/// appended to `out`.
fn collectSentences(
    allocator: std.mem.Allocator,
    text: []const u8,
    out: *std.array_list.Managed([]const u8),
) !void {
    var buf: std.array_list.Managed(u8) = .init(allocator);
    defer buf.deinit();

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // Parenthesised span -> recurse on the inside, drop it from this level.
        if (c == '(') {
            var depth: usize = 1;
            var j = i + 1;
            while (j < text.len) : (j += 1) {
                if (text[j] == '(') {
                    depth += 1;
                } else if (text[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            const inner_end = @min(j, text.len);
            try collectSentences(allocator, text[i + 1 .. inner_end], out);
            try buf.append(' ');
            i = if (j < text.len) j + 1 else text.len;
            continue;
        }
        if (c == ')') {
            i += 1;
            continue;
        }

        // Hard boundaries: newline and single-byte delimiters.
        if (c == '\n' or c == '?' or c == '!' or c == ':' or c == ',') {
            try flushSentence(allocator, &buf, out);
            i += 1;
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }

        // Bengali single danda (।, U+0964) and double danda (॥, U+0965).
        if (i + 3 <= text.len and text[i] == 0xE0 and text[i + 1] == 0xA5 and
            (text[i + 2] == 0xA4 or text[i + 2] == 0xA5))
        {
            try flushSentence(allocator, &buf, out);
            i += 3;
            continue;
        }

        try buf.append(c);
        i += 1;
    }

    try flushSentence(allocator, &buf, out);
}

/// Trims and space-normalizes the buffered candidate; appends it to `out` if it
/// is a clean Bangla sentence. Always clears `buf`.
fn flushSentence(
    allocator: std.mem.Allocator,
    buf: *std.array_list.Managed(u8),
    out: *std.array_list.Managed([]const u8),
) !void {
    defer buf.clearRetainingCapacity();

    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    if (trimmed.len == 0) return;

    const cleaned = try collapseSpaces(allocator, trimmed);
    if (isCleanBangla(cleaned)) try out.append(cleaned);
}

/// Collapses runs of spaces/tabs into a single space and trims the ends.
fn collapseSpaces(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var prev_space = false;
    for (input) |c| {
        if (c == ' ' or c == '\t') {
            if (!prev_space) try out.append(' ');
            prev_space = true;
        } else {
            try out.append(c);
            prev_space = false;
        }
    }
    return allocator.dupe(u8, std.mem.trim(u8, out.items, " "));
}

/// A sentence is "clean Bangla" when it contains at least two Bangla letters
/// and consists solely of Bangla characters, joiners, spaces and hyphens.
/// Anything else (Latin letters, ASCII digits, residual wiki markup such as
/// `{}[]|=$<>`) disqualifies it.
fn isCleanBangla(s: []const u8) bool {
    var letters: usize = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return false;
        if (cp >= 0x0980 and cp <= 0x09FF) {
            // Count letters/marks, but not the Bengali digits (U+09E6..U+09EF),
            // so purely numeric fragments don't qualify as sentences.
            if (cp < 0x09E6 or cp > 0x09EF) letters += 1;
            continue;
        }
        switch (cp) {
            ' ', '\t' => continue,
            0x200C, 0x200D => continue, // ZWNJ / ZWJ (conjunct joiners)
            '-', 0x2013, 0x2014 => continue, // hyphen, en dash, em dash
            else => return false,
        }
    }
    return letters >= 2;
}

fn writeCsvRow(out: *Io.Writer, page_id: []const u8, rev_id: []const u8, value: []const u8) !void {
    try out.writeAll(page_id);
    try out.writeByte(',');
    try out.writeAll(rev_id);
    try out.writeAll(",\"");
    for (value) |c| {
        if (c == '"') try out.writeByte('"'); // CSV escaping: " -> ""
        try out.writeByte(c);
    }
    try out.writeAll("\"\n");
}

fn reportProgress(pos: u64, total: u64, pages: usize, sentences: usize, title: []const u8) void {
    const percent: f64 = if (total > 0)
        @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(total)) * 100.0
    else
        0.0;
    std.debug.print("\r{d:6.2}% | {d} pages | {d} sentences | {s}\x1b[K", .{
        percent,
        pages,
        sentences,
        truncateUtf8(title, 48),
    });
}

/// Truncates a UTF-8 string to at most `max` bytes without splitting a
/// codepoint, so progress output never emits invalid UTF-8.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var it: std.unicode.Utf8Iterator = .{ .bytes = s, .i = 0 };
    var last: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        if (it.i > max) break;
        last = it.i;
    }
    return s[0..last];
}

// -- MediaWiki wikitext normalization ---------------------------------------
//
// Port of the JS `mediawikitoplaintext` pipeline. Each stage produces a new
// string; intermediates are allocated from a per-page arena so they do not need
// to be freed individually.
fn normalizeWikiMedia(allocator: std.mem.Allocator, wikitext: []const u8) ![]const u8 {
    var s: []const u8 = wikitext;

    s = try stripBetween(allocator, s, "<!--", "-->"); // comments
    s = try stripRefs(allocator, s); // references (tag + content, fully removed)
    s = try stripNested(allocator, s, "{{", "}}"); // templates / infoboxes (nested)
    s = try stripNested(allocator, s, "{|", "|}"); // tables (nested)
    s = try stripBracketPrefix(allocator, s, "[[File:", "]]"); // file links
    s = try stripBracketPrefix(allocator, s, "[[Image:", "]]"); // image links
    s = try stripBracketPrefix(allocator, s, "[[Category:", "]]"); // category links
    s = try transformInternalLinks(allocator, s); // [[a|b]] -> b, [[a]] -> a
    s = try transformExternalLinks(allocator, s); // [url text] -> text, [url] -> ''
    s = try removeAll(allocator, s, "'''"); // bold
    s = try removeAll(allocator, s, "''"); // italic
    s = try stripBetween(allocator, s, "<", ">"); // remaining HTML tags
    s = try stripHeadings(allocator, s); // == heading == -> heading
    s = try stripListMarkers(allocator, s); // leading * # : ;
    s = try collapseWhitespace(allocator, s); // collapse blank lines + trim

    return s;
}

/// Removes `<ref ...>...</ref>` spans (including their content) and
/// self-closing `<ref ... />` tags, so reference bodies never reach the output.
fn stripRefs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (startsWithIgnoreCase(input[i..], "<ref")) {
            // Confirm it is a <ref> tag (next char delimits the tag name).
            const after = if (i + 4 < input.len) input[i + 4] else 0;
            if (after == ' ' or after == '\t' or after == '\n' or after == '>' or after == '/') {
                if (std.mem.indexOfScalar(u8, input[i..], '>')) |gt_rel| {
                    const tag_end = i + gt_rel; // index of '>'
                    if (tag_end > 0 and input[tag_end - 1] == '/') {
                        // Self-closing <ref .../>
                        i = tag_end + 1;
                        continue;
                    }
                    // Paired <ref>...</ref>
                    if (indexOfIgnoreCase(input[tag_end..], "</ref>")) |close_rel| {
                        i = tag_end + close_rel + "</ref>".len;
                        continue;
                    }
                    // No closing tag: drop the remainder.
                    break;
                }
                break; // malformed, drop the remainder
            }
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Removes balanced `open ... close` groups, accounting for nesting (the way
/// MediaWiki templates and tables nest inside one another).
fn stripNested(allocator: std.mem.Allocator, input: []const u8, open: []const u8, close: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], open)) {
            var depth: usize = 1;
            i += open.len;
            while (i < input.len and depth > 0) {
                if (std.mem.startsWith(u8, input[i..], open)) {
                    depth += 1;
                    i += open.len;
                } else if (std.mem.startsWith(u8, input[i..], close)) {
                    depth -= 1;
                    i += close.len;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Removes every `open ... close` span (non-nested, shortest match), mirroring
/// a non-greedy `open[\s\S]*?close` regex.
fn stripBetween(allocator: std.mem.Allocator, input: []const u8, open: []const u8, close: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], open)) {
            const rest = i + open.len;
            if (std.mem.indexOf(u8, input[rest..], close)) |rel| {
                i = rest + rel + close.len;
                continue;
            }
            // No closing token: not a match, keep the opening byte and move on.
            try out.append(input[i]);
            i += 1;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Removes `open ... close` spans where `open` is matched case-insensitively
/// (used for `[[File:`, `[[Image:`, `[[Category:`).
fn stripBracketPrefix(allocator: std.mem.Allocator, input: []const u8, open: []const u8, close: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (startsWithIgnoreCase(input[i..], open)) {
            const rest = i + open.len;
            if (std.mem.indexOf(u8, input[rest..], close)) |rel| {
                i = rest + rel + close.len;
                continue;
            }
            try out.append(input[i]);
            i += 1;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// `[[link|text]]` -> `text`, `[[link]]` -> `link`.
fn transformInternalLinks(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "[[")) {
            const inner_start = i + 2;
            if (std.mem.indexOf(u8, input[inner_start..], "]]")) |rel| {
                const inner = input[inner_start .. inner_start + rel];
                if (std.mem.indexOfScalar(u8, inner, '|')) |p| {
                    try out.appendSlice(inner[p + 1 ..]);
                } else {
                    try out.appendSlice(inner);
                }
                i = inner_start + rel + 2;
                continue;
            }
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// `[http://... text]` -> `text`, `[http://...]` -> ``.
fn transformExternalLinks(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "[http://") or
            std.mem.startsWith(u8, input[i..], "[https://"))
        {
            if (std.mem.indexOfScalar(u8, input[i..], ']')) |rel| {
                const inner = input[i + 1 .. i + rel];
                if (std.mem.indexOfAny(u8, inner, " \t")) |sp| {
                    try out.appendSlice(std.mem.trimStart(u8, inner[sp..], " \t"));
                }
                i = i + rel + 1;
                continue;
            }
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Removes every occurrence of `token`.
fn removeAll(allocator: std.mem.Allocator, input: []const u8, token: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], token)) {
            i += token.len;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Drops runs of two or more `=`, turning `== Heading ==` into ` Heading `.
fn stripHeadings(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '=') {
            var j = i;
            while (j < input.len and input[j] == '=') j += 1;
            const run = j - i;
            if (run < 2) try out.append('=');
            i = j;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// Removes leading list markers (`*`, `#`, `:`, `;`) and the spaces/tabs that
/// follow them at the start of each line.
fn stripListMarkers(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    var at_line_start = true;
    while (i < input.len) {
        if (at_line_start) {
            const marker_start = i;
            while (i < input.len and isListMarker(input[i])) i += 1;
            if (i > marker_start) {
                while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
            }
            at_line_start = false;
            continue;
        }
        const c = input[i];
        try out.append(c);
        i += 1;
        if (c == '\n') at_line_start = true;
    }
    return out.toOwnedSlice();
}

/// Collapses runs of 3+ newlines into 2 and trims surrounding whitespace.
fn collapseWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\n') {
            var j = i;
            while (j < input.len and input[j] == '\n') j += 1;
            const run = j - i;
            try out.appendNTimes('\n', if (run >= 3) 2 else run);
            i = j;
            continue;
        }
        try out.append(input[i]);
        i += 1;
    }

    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn isListMarker(c: u8) bool {
    return c == '*' or c == '#' or c == ':' or c == ';';
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |n, idx| {
        if (std.ascii.toLower(haystack[idx]) != std.ascii.toLower(n)) return false;
    }
    return true;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (startsWithIgnoreCase(haystack[i..], needle)) return i;
    }
    return null;
}
