//! Assemble `spell.db` from `export` CSVs with the `sqlite3` shell.
//!
//! Every path is explicit so `zig build db` can run this as a cached step:
//!
//!   prepare --data <data exe> --sqlite3 <sqlite3 exe> --schema <schema.sql>
//!           --export <export_id dir> --seed <confusions_seed.csv>
//!           --work <scratch dir> --out <spell.db>
//!           [--avro <words.txt>] [--debug]
//!
//! With `--avro`, Avro IME words (one per line) are appended to the Wikipedia
//! dictionary (synthetic frequency 1) before SymSpell / import. `--debug`
//! builds the text-keyed debug DB from `export/` (no confusions table).

const std = @import("std");
const Io = std.Io;
const process = std.process;

/// Frequency assigned to Avro-only lemmas (unattested in wiki). Kept low so
/// Wikipedia-attested candidates still win ranking ties.
const AVRO_FREQUENCY: u64 = 1;

const Args = struct {
    data: []const u8,
    sqlite3: []const u8,
    schema: []const u8,
    @"export": []const u8,
    seed: []const u8,
    work: []const u8,
    out: []const u8,
    avro: ?[]const u8 = null,
    debug: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const argv = try init.minimal.args.toSlice(arena);
    var parsed: struct {
        data: ?[]const u8 = null,
        sqlite3: ?[]const u8 = null,
        schema: ?[]const u8 = null,
        @"export": ?[]const u8 = null,
        seed: ?[]const u8 = null,
        work: ?[]const u8 = null,
        out: ?[]const u8 = null,
        avro: ?[]const u8 = null,
        debug: bool = false,
    } = .{};
    var i: usize = 1;
    flags: while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--debug")) {
            parsed.debug = true;
            continue;
        }
        inline for (.{ "data", "sqlite3", "schema", "export", "seed", "work", "out", "avro" }) |name| {
            if (std.mem.eql(u8, a, "--" ++ name)) {
                i += 1;
                if (i >= argv.len) return error.InvalidArguments;
                @field(parsed, name) = argv[i];
                continue :flags;
            }
        }
        std.debug.print("unexpected arg: {s}\n", .{a});
        return error.InvalidArguments;
    }
    var args: Args = .{
        .data = undefined,
        .sqlite3 = undefined,
        .schema = undefined,
        .@"export" = undefined,
        .seed = undefined,
        .work = undefined,
        .out = undefined,
        .avro = parsed.avro,
        .debug = parsed.debug,
    };
    inline for (.{ "data", "sqlite3", "schema", "export", "seed", "work", "out" }) |name| {
        @field(args, name) = @field(parsed, name) orelse {
            std.debug.print("error: missing --{s}\n", .{name});
            return error.InvalidArguments;
        };
    }

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, args.work);
    const exp = args.@"export";
    const id_mode = !args.debug;

    var dictionary = try std.fs.path.join(arena, &.{ exp, "dictionary.csv" });
    if (args.avro) |avro| {
        std.debug.print("\n==> [1/4] Merge Avro lexicon into Wikipedia dictionary\n", .{});
        const merged = try std.fs.path.join(arena, &.{ args.work, "dictionary_prepared.csv" });
        const stats = try mergeAvroDictionary(gpa, io, .{
            .wiki_csv = dictionary,
            .avro_words = avro,
            .out_csv = merged,
            .id_mode = id_mode,
        });
        std.debug.print(
            "    wiki={d} + avro_new={d} → {d} words\n",
            .{ stats.wiki_count, stats.avro_added, stats.total },
        );
        dictionary = merged;
    } else {
        std.debug.print("\n==> [1/4] skip Avro merge (no --avro)\n", .{});
    }

    std.debug.print("\n==> [2/4] SymSpell deletes ({s} mode)\n", .{if (id_mode) "word_id" else "word"});
    const deletes = try std.fs.path.join(arena, &.{ args.work, "deletes.csv" });
    try runData(gpa, io, args.data, &.{ "--symspell-deletes", dictionary, "--out", deletes });

    var confusions: ?[]const u8 = null;
    if (id_mode) {
        std.debug.print("\n==> [3/4] Mine confusion weights\n", .{});
        const c = try std.fs.path.join(arena, &.{ args.work, "confusions.csv" });
        const mined = try std.fs.path.join(arena, &.{ args.work, "confusions_mined.csv" });
        try runData(gpa, io, args.data, &.{ "--mine-confusions", dictionary, args.seed, "--out", c, "--out-mined", mined });
        confusions = c;
    } else {
        std.debug.print("\n==> [3/4] skip confusions (debug DB)\n", .{});
    }

    std.debug.print("\n==> [4/4] Assemble {s}\n", .{args.out});
    try assemble(gpa, io, args, .{
        .dictionary = dictionary,
        .deletes = deletes,
        .bigrams = try std.fs.path.join(arena, &.{ exp, "bigrams.csv" }),
        .trigrams = try std.fs.path.join(arena, &.{ exp, "trigrams.csv" }),
        .confusions = confusions,
    });

    std.debug.print("\n==> prepare done → {s}\n", .{args.out});
}

const MergeStats = struct {
    wiki_count: usize,
    avro_added: usize,
    total: usize,
};

const MergeOptions = struct {
    wiki_csv: []const u8,
    /// One word per line, no header.
    avro_words: []const u8,
    out_csv: []const u8,
    /// true → input/output `id,word,frequency`; false → `word,frequency`
    id_mode: bool,
};

/// Append Avro-only words onto the Wikipedia dictionary CSV.
/// Existing wiki frequencies are preserved; new lemmas get `AVRO_FREQUENCY`.
fn mergeAvroDictionary(gpa: std.mem.Allocator, io: Io, opts: MergeOptions) !MergeStats {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var seen: std.StringHashMapUnmanaged(void) = .empty;

    var out_file = try Io.Dir.cwd().createFile(io, opts.out_csv, .{});
    defer out_file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;

    if (opts.id_mode) {
        try out.writeAll("id,word,frequency\n");
    } else {
        try out.writeAll("word,frequency\n");
    }

    var wiki_count: usize = 0;
    var next_id: u64 = 1;

    {
        var in_file = try Io.Dir.cwd().openFile(io, opts.wiki_csv, .{});
        defer in_file.close(io);
        var in_buf: [64 * 1024]u8 = undefined;
        var in_reader = in_file.reader(io, &in_buf);
        const in = &in_reader.interface;

        var header_done = false;
        while (try in.takeDelimiter('\n')) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r\n");
            if (!header_done) {
                header_done = true;
                continue;
            }
            if (line.len == 0) continue;

            const word = if (opts.id_mode)
                parseIdWord(line) orelse continue
            else
                parseWordFreqWord(line) orelse continue;

            const owned = try arena.dupe(u8, word);
            try seen.put(arena, owned, {});

            try out.writeAll(line);
            try out.writeByte('\n');
            wiki_count += 1;

            if (opts.id_mode) {
                if (parseId(line)) |id| {
                    if (id >= next_id) next_id = id + 1;
                }
            }
        }
    }

    var avro_added: usize = 0;
    {
        var in_file = try Io.Dir.cwd().openFile(io, opts.avro_words, .{});
        defer in_file.close(io);
        var in_buf: [64 * 1024]u8 = undefined;
        var in_reader = in_file.reader(io, &in_buf);
        const in = &in_reader.interface;

        while (try in.takeDelimiter('\n')) |raw_line| {
            const word = std.mem.trimEnd(u8, raw_line, "\r\n");
            if (word.len == 0) continue;
            if (seen.contains(word)) continue;

            const owned = try arena.dupe(u8, word);
            try seen.put(arena, owned, {});

            if (opts.id_mode) {
                try out.print("{d},", .{next_id});
                next_id += 1;
            }
            try writeCsvField(out, word);
            try out.print(",{d}\n", .{AVRO_FREQUENCY});
            avro_added += 1;
        }
    }

    try out.flush();
    return .{
        .wiki_count = wiki_count,
        .avro_added = avro_added,
        .total = wiki_count + avro_added,
    };
}

fn parseId(line: []const u8) ?u64 {
    const c1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, line[0..c1], " \t"), 10) catch null;
}

fn parseIdWord(line: []const u8) ?[]const u8 {
    const c1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ',') orelse return null;
    return stripCsvQuotes(line[c1 + 1 .. c2]);
}

fn parseWordFreqWord(line: []const u8) ?[]const u8 {
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    return stripCsvQuotes(line[0..comma]);
}

fn stripCsvQuotes(field: []const u8) []const u8 {
    if (field.len >= 2 and field[0] == '"' and field[field.len - 1] == '"') {
        return field[1 .. field.len - 1];
    }
    return field;
}

fn writeCsvField(out: anytype, field: []const u8) !void {
    const needs_quote = std.mem.indexOfAny(u8, field, ",\"\n\r") != null;
    if (!needs_quote) {
        try out.writeAll(field);
        return;
    }
    try out.writeByte('"');
    for (field) |c| {
        if (c == '"') try out.writeAll("\"\"") else try out.writeByte(c);
    }
    try out.writeByte('"');
}

const Tables = struct {
    dictionary: []const u8,
    deletes: []const u8,
    bigrams: []const u8,
    trigrams: []const u8,
    confusions: ?[]const u8,
};

fn assemble(gpa: std.mem.Allocator, io: Io, args: Args, t: Tables) !void {
    Io.Dir.cwd().deleteFile(io, args.out) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    // sqlite3 .import needs literal paths; build the script with the chosen CSVs.
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    try script.print(gpa,
        \\.echo off
        \\.timer on
        \\.print '→ creating schema…'
        \\.read '{s}'
        \\.mode csv
        \\.print '→ importing dictionary…'
        \\.import --skip 1 '{s}' dictionary
        \\.print '→ importing deletes (largest step)…'
        \\.import --skip 1 '{s}' deletes
        \\.print '→ importing bigrams…'
        \\.import --skip 1 '{s}' bigrams
        \\.print '→ importing trigrams…'
        \\.import --skip 1 '{s}' trigrams
        \\
    , .{ args.schema, t.dictionary, t.deletes, t.bigrams, t.trigrams });
    if (t.confusions) |c| try script.print(gpa,
        \\.print '→ importing confusions…'
        \\.import --skip 1 '{s}' confusions
        \\
    , .{c});
    try script.appendSlice(gpa,
        \\.print '→ VACUUM + ANALYZE…'
        \\VACUUM;
        \\ANALYZE;
        \\.headers on
        \\.mode column
        \\SELECT 'dictionary' AS t, COUNT(*) AS n FROM dictionary
        \\UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
        \\UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
        \\UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;
        \\SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
        \\FROM pragma_page_count(), pragma_page_size();
        \\
    );

    const script_path = try std.fs.path.join(gpa, &.{ args.work, "prepare.sql" });
    defer gpa.free(script_path);
    try writeAll(io, script_path, script.items);
    try runSqlite3(io, args.sqlite3, args.out, script_path);
}

fn runSqlite3(io: Io, sqlite3: []const u8, db_path: []const u8, script_path: []const u8) !void {
    const script_file = try Io.Dir.cwd().openFile(io, script_path, .{});
    // Ownership transferred into spawn stdin; wait before return.
    var child = try process.spawn(io, .{
        .argv = &.{ sqlite3, db_path },
        .stdin = .{ .file = script_file },
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("error: sqlite3 failed ({any})\n", .{term});
        return error.SqliteFailed;
    }
}

fn runData(gpa: std.mem.Allocator, io: Io, data_exe: []const u8, extra: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, data_exe);
    try argv.appendSlice(gpa, extra);

    var child = try process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("error: {s} failed ({any})\n", .{ data_exe, term });
        return error.DataExeFailed;
    }
}

fn writeAll(io: Io, path: []const u8, contents: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}
