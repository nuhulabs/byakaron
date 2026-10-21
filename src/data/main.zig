const std = @import("std");
const Io = std.Io;
const log = std.log;
const xml = @import("xml");
const Tokenizer = @import("tokenization").Tokenizer;
const Bz2Reader = @import("Bz2Reader.zig");

/// Progress of the running mode; joins `zig build`'s tree via ZIG_PROGRESS.
var progress: std.Progress.Node = .none;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    // Parse a tiny CLI: optional mode flag plus a single positional input path.
    //   (default)              MediaWiki XML (or .xml.bz2) → sentences.csv
    //   --wordtriplets         sentences.csv → word_triplets.csv
    //                          optional --limit N (sample run → *_sample.csv + words_sample.csv)
    //   --symspell-deletes     dictionary.csv → deletes.csv
    //                          accepts word,frequency OR id,word,frequency
    //   --mine-confusions      dictionary.csv [confusions_seed.csv]
    //                          → confusions_mined.csv + confusions.csv (reweighted)
    // `--out <path>` overrides the primary output (and `--out-mined <path>` the
    // mined confusions); `zig build db` passes build-cache paths for both.
    var mode: enum { sentences, word_triplets, symspell_deletes, mine_confusions } = .sentences;
    var positional: ?[]const u8 = null;
    var secondary: ?[]const u8 = null;
    var limit: ?usize = null;
    var out: ?[]const u8 = null;
    var out_mined: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--wordtriplets")) {
            mode = .word_triplets;
        } else if (std.mem.eql(u8, a, "--symspell-deletes")) {
            mode = .symspell_deletes;
        } else if (std.mem.eql(u8, a, "--mine-confusions")) {
            mode = .mine_confusions;
        } else if (std.mem.eql(u8, a, "--limit")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            out = args[i];
        } else if (std.mem.eql(u8, a, "--out-mined")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            out_mined = args[i];
        } else if (positional == null) {
            positional = a;
        } else {
            secondary = a;
        }
    }

    progress = std.Progress.start(io, .{ .root_name = switch (mode) {
        .sentences => "sentences (MiB)",
        .word_triplets => "word triplets (MiB)",
        .symspell_deletes => "SymSpell deletes (words)",
        .mine_confusions => "mine confusions (words)",
    } });
    defer progress.end();

    switch (mode) {
        .word_triplets => try runWordTriplets(
            gpa,
            io,
            positional orelse "sentences.csv",
            limit,
            out orelse if (limit != null) "word_triplets_sample.csv" else "word_triplets.csv",
        ),
        .symspell_deletes => try runSymSpellDeletes(gpa, io, positional orelse "dictionary.csv", out orelse "deletes.csv"),
        .mine_confusions => try runMineConfusions(
            gpa,
            io,
            positional orelse "dictionary.csv",
            secondary orelse "src/data/queries/confusions_seed.csv",
            out orelse "confusions.csv",
            out_mined orelse "confusions_mined.csv",
        ),
        .sentences => try runSentences(
            gpa,
            io,
            positional orelse return error.InvalidArguments,
            out orelse "sentences.csv",
        ),
    }
}

/// Streams a MediaWiki XML dump (plain or `.bz2`) and writes one clean Bangla
/// sentence per row to `out_path` (page_id, rev_id, value).
fn runSentences(gpa: std.mem.Allocator, io: Io, input_path: []const u8, out_path: []const u8) !void {
    var input_file = try Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var input_buf: [64 * 1024]u8 = undefined;
    var input_reader = input_file.reader(io, &input_buf);

    // Total file size is used to render progress without ever loading the whole
    // document into memory (we stream it node-by-node below).
    const total_size: u64 = input_reader.getSize() catch 0;

    // Progress tracks the (compressed) file position either way.
    var bz2_buf: [64 * 1024]u8 = undefined;
    var bz2: ?Bz2Reader = if (std.mem.endsWith(u8, input_path, ".bz2"))
        Bz2Reader.init(&input_reader.interface, &bz2_buf)
    else
        null;
    defer if (bz2) |*z| z.deinit();
    const xml_input = if (bz2) |*z| &z.interface else &input_reader.interface;

    var streaming_reader: xml.Reader.Streaming = .init(gpa, xml_input, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
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
}

/// Reads the `value` column of sentences.csv, tokenizes each sentence with
/// `byakaron.Tokenization` (nukta-normalized Bangla words), and writes every
/// consecutive word triplet to word_triplets.csv (value, mid_value, next_value).
///
/// With `--limit N`, also writes `words_sample.csv` (and the default output
/// becomes `word_triplets_sample.csv`) so a full corpus file is not overwritten.
fn runWordTriplets(gpa: std.mem.Allocator, io: Io, input_path: []const u8, limit: ?usize, triplets_path: []const u8) !void {
    var in_file = try Io.Dir.cwd().openFile(io, input_path, .{});
    defer in_file.close(io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);
    const total_size: u64 = in_reader.getSize() catch 0;
    const in = &in_reader.interface;

    var out_file = try Io.Dir.cwd().createFile(io, triplets_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;
    try out.writeAll("value,mid_value,next_value\n");

    // Per-line scratch for tokenizer AST + normalized strings.
    var line_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer line_arena_state.deinit();

    // Unique words when sampling (for words_sample.csv validation).
    var unique: std.StringHashMapUnmanaged(void) = .empty;
    defer unique.deinit(gpa);
    var unique_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer unique_arena_state.deinit();

    var line_count: usize = 0;
    var sentence_rows: usize = 0;
    var triplet_count: usize = 0;
    var last_report: usize = 0;
    var header_checked = false;

    while (try in.takeDelimiter('\n')) |raw_line| {
        if (!header_checked) {
            header_checked = true;
            if (std.mem.startsWith(u8, raw_line, "page_id")) continue;
        }

        if (limit) |n| {
            if (sentence_rows >= n) break;
        }

        const value = extractCsvValue(raw_line) orelse continue;
        sentence_rows += 1;

        _ = line_arena_state.reset(.retain_capacity);
        const arena = line_arena_state.allocator();

        const words = Tokenizer.wordsFromText(arena, value, .{ .normalize = true }) catch continue;
        if (words.len < 3) continue;

        line_count += 1;
        var wi: usize = 0;
        while (wi + 2 < words.len) : (wi += 1) {
            try writeTripletRow(out, words[wi], words[wi + 1], words[wi + 2]);
            triplet_count += 1;
        }

        if (limit != null) {
            const ua = unique_arena_state.allocator();
            for (words) |w| {
                const gop = try unique.getOrPut(gpa, w);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try ua.dupe(u8, w);
                }
            }
        }

        if (line_count - last_report >= 100_000) {
            last_report = line_count;
            reportTripletProgress(in_reader.pos, total_size, line_count, triplet_count);
        }
    }

    try out.flush();
    reportTripletProgress(in_reader.pos, total_size, line_count, triplet_count);

    if (limit != null) {
        var words_file = try Io.Dir.cwd().createFile(io, "words_sample.csv", .{});
        defer words_file.close(io);
        var words_buf: [16 * 1024]u8 = undefined;
        var words_writer = words_file.writer(io, &words_buf);
        const wout = &words_writer.interface;
        try wout.writeAll("word\n");
        var uit = unique.keyIterator();
        while (uit.next()) |k| {
            try writeCsvField(wout, k.*);
            try wout.writeByte('\n');
        }
        try wout.flush();
        std.debug.print("Wrote {d} unique words -> words_sample.csv\n", .{unique.count()});
    }
}

/// Counts lexicon word pairs that differ by exactly one seeded confusion
/// substitution (built from the Wikipedia-derived dictionary). Rewrites
/// confusions.csv with soft-blended weights: known lookalikes stay prioritized
/// when many real orthographic twins exist in the corpus lexicon.
fn runMineConfusions(
    gpa: std.mem.Allocator,
    io: Io,
    dictionary_path: []const u8,
    seed_path: []const u8,
    out_path: []const u8,
    mined_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var words: std.StringHashMapUnmanaged(void) = .empty;
    try loadDictionaryWords(gpa, io, arena, dictionary_path, &words);

    const edges = try loadConfusionSeed(arena, io, seed_path);
    var counts: std.StringHashMapUnmanaged(u64) = .empty;

    var wit = words.keyIterator();
    var scanned: usize = 0;
    while (wit.next()) |wp| {
        const word = wp.*;
        scanned += 1;
        for (edges) |edge| {
            var i: usize = 0;
            while (i < word.len) {
                if (std.mem.startsWith(u8, word[i..], edge.from_g)) {
                    const variant = try concatReplace(arena, word, i, edge.from_g.len, edge.to_g);
                    if (!std.mem.eql(u8, variant, word) and words.contains(variant)) {
                        const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}\x1f{s}", .{ edge.from_g, edge.to_g, edge.kind });
                        const gop = try counts.getOrPut(arena, key);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
                const len = std.unicode.utf8ByteSequenceLength(word[i]) catch {
                    i += 1;
                    continue;
                };
                if (i + len > word.len) break;
                i += len;
            }
        }
        if (scanned % 1_000 == 0) {
            progress.setEstimatedTotalItems(words.count());
            progress.setCompletedItems(scanned);
        }
    }

    var mined_file = try Io.Dir.cwd().createFile(io, mined_path, .{});
    defer mined_file.close(io);
    var mined_buf: [16 * 1024]u8 = undefined;
    var mined_writer = mined_file.writer(io, &mined_buf);
    const mined_out = &mined_writer.interface;
    try mined_out.writeAll("from_g,to_g,kind,pair_count\n");

    var count_lookup: std.StringHashMapUnmanaged(u64) = .empty;
    var cit = counts.iterator();
    while (cit.next()) |e| {
        var parts = std.mem.splitScalar(u8, e.key_ptr.*, '\x1f');
        const from_g = parts.next() orelse continue;
        const to_g = parts.next() orelse continue;
        const kind = parts.next() orelse continue;
        try writeCsvRow4(mined_out, from_g, to_g, kind, e.value_ptr.*);
        const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}\x1f{s}", .{ from_g, to_g, kind });
        try count_lookup.put(arena, key, e.value_ptr.*);
    }
    try mined_out.flush();

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;
    try out.writeAll("from_g,to_g,weight,kind\n");

    for (edges) |edge| {
        const key = try std.fmt.allocPrint(arena, "{s}\x1f{s}\x1f{s}", .{ edge.from_g, edge.to_g, edge.kind });
        var weight = edge.weight;
        if (count_lookup.get(key)) |n| {
            // Soft blend: more lexicon twins → slightly lower weight (more likely).
            const mined = 1.0 / (1.0 + @log(@as(f64, @floatFromInt(n + 1))));
            weight = @max(0.12, @min(edge.weight, mined));
        }
        try writeConfusionRow(out, edge.from_g, edge.to_g, weight, edge.kind);
    }
    try out.flush();
}

const SeedEdge = struct {
    from_g: []const u8,
    to_g: []const u8,
    weight: f64,
    kind: []const u8,
};

fn loadDictionaryWords(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    path: []const u8,
    words: *std.StringHashMapUnmanaged(void),
) !void {
    _ = gpa;
    var in_file = try Io.Dir.cwd().openFile(io, path, .{});
    defer in_file.close(io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);
    const in = &in_reader.interface;

    var header_checked = false;
    var id_mode = false;
    while (try in.takeDelimiter('\n')) |raw_line| {
        if (!header_checked) {
            header_checked = true;
            const header = std.mem.trimEnd(u8, raw_line, "\r\n");
            if (std.mem.startsWith(u8, header, "id,")) {
                id_mode = true;
                continue;
            }
            if (std.mem.startsWith(u8, header, "word")) continue;
        }
        const line = std.mem.trimEnd(u8, raw_line, "\r\n");
        if (line.len == 0) continue;
        const parsed = if (id_mode) parseDictionaryIdRow(line) else parseDictionaryWordRow(line);
        const row = parsed orelse continue;
        const duped = try arena.dupe(u8, row.word);
        try words.put(arena, duped, {});
    }
}

fn loadConfusionSeed(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const SeedEdge {
    var in_file = try Io.Dir.cwd().openFile(io, path, .{});
    defer in_file.close(io);
    var in_buf: [16 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);
    const in = &in_reader.interface;

    var list: std.ArrayList(SeedEdge) = .empty;
    var header_checked = false;
    while (try in.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r\n");
        if (line.len == 0) continue;
        if (!header_checked) {
            header_checked = true;
            if (std.mem.startsWith(u8, line, "from_g")) continue;
        }
        var parts = std.mem.splitScalar(u8, line, ',');
        const from_g = parts.next() orelse continue;
        const to_g = parts.next() orelse continue;
        const weight_s = parts.next() orelse continue;
        const kind = parts.next() orelse "ortho";
        const weight = std.fmt.parseFloat(f64, weight_s) catch continue;
        try list.append(arena, .{
            .from_g = try arena.dupe(u8, from_g),
            .to_g = try arena.dupe(u8, to_g),
            .weight = weight,
            .kind = try arena.dupe(u8, kind),
        });
    }
    return try list.toOwnedSlice(arena);
}

fn concatReplace(allocator: std.mem.Allocator, s: []const u8, at: usize, from_len: usize, to_g: []const u8) ![]const u8 {
    const after = at + from_len;
    const buf = try allocator.alloc(u8, at + to_g.len + (s.len - after));
    @memcpy(buf[0..at], s[0..at]);
    @memcpy(buf[at .. at + to_g.len], to_g);
    @memcpy(buf[at + to_g.len ..], s[after..]);
    return buf;
}

fn writeConfusionRow(out: *Io.Writer, from_g: []const u8, to_g: []const u8, weight: f64, kind: []const u8) !void {
    try writeCsvField(out, from_g);
    try out.writeByte(',');
    try writeCsvField(out, to_g);
    try out.writeByte(',');
    try out.print("{d:.2}", .{weight});
    try out.writeByte(',');
    try writeCsvField(out, kind);
    try out.writeByte('\n');
}

fn writeCsvRow4(out: *Io.Writer, a: []const u8, b: []const u8, c: []const u8, n: u64) !void {
    try writeCsvField(out, a);
    try out.writeByte(',');
    try writeCsvField(out, b);
    try out.writeByte(',');
    try writeCsvField(out, c);
    try out.writeByte(',');
    try out.print("{d}\n", .{n});
}

/// Reads dictionary.csv and writes SymSpell delete variants to deletes.csv.
///
/// Input formats:
///   - `word,frequency`          → output `delete_key,word`
///   - `id,word,frequency`       → output `delete_key,word_id` (optimized)
///
/// Deletes are generated on Unicode codepoints up to edit distance 2.
fn runSymSpellDeletes(gpa: std.mem.Allocator, io: Io, input_path: []const u8, out_path: []const u8) !void {
    const max_edit_distance: u8 = 2;

    var in_file = try Io.Dir.cwd().openFile(io, input_path, .{});
    defer in_file.close(io);
    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);
    const in = &in_reader.interface;

    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;

    var line_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer line_arena_state.deinit();

    var seen: std.StringHashMap(void) = .init(gpa);
    defer seen.deinit();

    var word_count: usize = 0;
    var delete_count: usize = 0;
    var header_checked = false;
    var id_mode = false;

    while (try in.takeDelimiter('\n')) |raw_line| {
        if (!header_checked) {
            header_checked = true;
            const header = std.mem.trimEnd(u8, raw_line, "\r\n");
            if (std.mem.startsWith(u8, header, "id,")) {
                id_mode = true;
                try out.writeAll("delete_key,word_id\n");
                continue;
            }
            if (std.mem.startsWith(u8, header, "word")) {
                try out.writeAll("delete_key,word\n");
                continue;
            }
            // No header — assume text mode and process this line.
            try out.writeAll("delete_key,word\n");
        }

        const line = std.mem.trimEnd(u8, raw_line, "\r\n");
        if (line.len == 0) continue;

        const parsed = if (id_mode)
            parseDictionaryIdRow(line)
        else
            parseDictionaryWordRow(line);
        const row = parsed orelse continue;

        // Clear hash keys before resetting the arena that owns them.
        seen.clearRetainingCapacity();
        _ = line_arena_state.reset(.retain_capacity);
        const arena = line_arena_state.allocator();

        try emitDeletes(arena, &seen, out, row.ref, row.word, max_edit_distance, &delete_count);
        word_count += 1;
        if (word_count % 1_000 == 0) progress.setCompletedItems(word_count);
    }

    try out.flush();
}

const DictionaryRow = struct {
    /// Value written in the second CSV column (word text or word_id).
    ref: []const u8,
    /// Surface form used to generate delete variants.
    word: []const u8,
};

fn parseDictionaryWordRow(line: []const u8) ?DictionaryRow {
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    var word = line[0..comma];
    if (word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"') {
        word = word[1 .. word.len - 1];
    }
    if (word.len == 0) return null;
    return .{ .ref = word, .word = word };
}

fn parseDictionaryIdRow(line: []const u8) ?DictionaryRow {
    const c1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ',') orelse return null;
    const id = std.mem.trim(u8, line[0..c1], " \t");
    var word = line[c1 + 1 .. c2];
    if (word.len >= 2 and word[0] == '"' and word[word.len - 1] == '"') {
        word = word[1 .. word.len - 1];
    }
    if (id.len == 0 or word.len == 0) return null;
    return .{ .ref = id, .word = word };
}

/// Recursively emits delete-only variants of `current` that map back to `ref`
/// (`ref` is either the original word or its integer id as text).
fn emitDeletes(
    allocator: std.mem.Allocator,
    seen: *std.StringHashMap(void),
    out: *Io.Writer,
    ref: []const u8,
    current: []const u8,
    distance_left: u8,
    delete_count: *usize,
) !void {
    if (distance_left == 0) return;

    var cps: std.array_list.Managed([]const u8) = .init(allocator);
    defer cps.deinit();
    try utf8CodepointSlices(current, &cps);
    if (cps.items.len == 0) return;

    var i: usize = 0;
    while (i < cps.items.len) : (i += 1) {
        const deleted = try concatCodepointsExcept(allocator, cps.items, i);
        const gop = try seen.getOrPut(deleted);
        if (gop.found_existing) continue;
        gop.value_ptr.* = {};

        try writeDeleteRow(out, deleted, ref);
        delete_count.* += 1;
        try emitDeletes(allocator, seen, out, ref, deleted, distance_left - 1, delete_count);
    }
}

fn utf8CodepointSlices(s: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) break;
        try out.append(s[i .. i + len]);
        i += len;
    }
}

fn concatCodepointsExcept(allocator: std.mem.Allocator, cps: []const []const u8, skip: usize) ![]const u8 {
    var total: usize = 0;
    for (cps, 0..) |cp, i| {
        if (i != skip) total += cp.len;
    }
    const buf = try allocator.alloc(u8, total);
    var o: usize = 0;
    for (cps, 0..) |cp, i| {
        if (i == skip) continue;
        @memcpy(buf[o .. o + cp.len], cp);
        o += cp.len;
    }
    return buf;
}

fn writeDeleteRow(out: *Io.Writer, delete_key: []const u8, ref: []const u8) !void {
    try writeCsvField(out, delete_key);
    try out.writeByte(',');
    try writeCsvField(out, ref);
    try out.writeByte('\n');
}

/// Extracts the third CSV column (`value`) from a `page_id,rev_id,"value"` row.
/// Surrounding quotes are stripped; residual punctuation is handled by the
/// shared Bangla tokenizer, so we don't bother un-escaping `""` here.
fn extractCsvValue(line: []const u8) ?[]const u8 {
    const c1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ',') orelse return null;
    var field = std.mem.trimEnd(u8, line[c2 + 1 ..], "\r\n");
    if (field.len >= 2 and field[0] == '"' and field[field.len - 1] == '"') {
        field = field[1 .. field.len - 1];
    }
    return field;
}

fn writeTripletRow(out: *Io.Writer, value: []const u8, mid_value: []const u8, next_value: []const u8) !void {
    try writeCsvField(out, value);
    try out.writeByte(',');
    try writeCsvField(out, mid_value);
    try out.writeByte(',');
    try writeCsvField(out, next_value);
    try out.writeByte('\n');
}

/// Writes a CSV field, quoting/escaping only when the value contains a comma,
/// quote or newline (it won't for clean Bangla words, but stay correct anyway).
fn writeCsvField(out: *Io.Writer, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\n\r") == null) {
        try out.writeAll(s);
        return;
    }
    try out.writeByte('"');
    for (s) |c| {
        if (c == '"') try out.writeByte('"');
        try out.writeByte(c);
    }
    try out.writeByte('"');
}

fn reportTripletProgress(pos: u64, total: u64, sentences: usize, triplets: usize) void {
    var buf: [64]u8 = undefined;
    progress.setName(std.fmt.bufPrint(&buf, "word triplets: {d} sentences, {d} triplets (MiB)", .{ sentences, triplets }) catch "word triplets (MiB)");
    progress.setEstimatedTotalItems(@intCast(total >> 20));
    progress.setCompletedItems(@intCast(pos >> 20));
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
    _ = title;
    var buf: [64]u8 = undefined;
    progress.setName(std.fmt.bufPrint(&buf, "sentences: {d} pages, {d} sentences (MiB)", .{ pages, sentences }) catch "sentences (MiB)");
    progress.setEstimatedTotalItems(@intCast(total >> 20));
    progress.setCompletedItems(@intCast(pos >> 20));
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
