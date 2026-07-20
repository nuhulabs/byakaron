//! Assemble `spell.db` from `export_id/` CSVs via the `sqlite3` CLI.
//!
//!   zig build export            # once (word_triplets → CSVs)
//!   zig build prepare           # merge Avro + SymSpell + confusions + sqlite3 → spell.db
//!   zig build prepare -- --debug-db
//!   zig build prepare -- --no-avro          # wiki-only lexicon
//!
//! By default, Avro IME words from `dictionary_macos.csv` are appended to the
//! Wikipedia dictionary (synthetic frequency 1) before SymSpell / import.
//!
//! Requires `sqlite3` on PATH. Pass the `data` exe path as the first argument
//! when invoked from the build system.

const std = @import("std");
const Io = std.Io;
const process = std.process;

const SCHEMA_ID = "src/queries/10_sqlite_schema_id.sql";
const SCHEMA_DEBUG = "src/queries/07_sqlite_schema.sql";
const SEED = "src/queries/confusions_seed.csv";
const EXPORT_ID = "export_id";
const EXPORT_DEBUG = "export";
const SPELL_DB = "spell.db";
const SPELL_DEBUG_DB = "spell_debug.db";
const WEBZ_DEFAULT_DB = "../../platforms/webz/zig-out/data/db/default.db";
const AVRO_DICT = "dictionary_macos.csv";
const DICT_PREPARED_ID = "export_id/dictionary_prepared.csv";
const DICT_PREPARED_DEBUG = "export/dictionary_prepared.csv";
/// Frequency assigned to Avro-only lemmas (unattested in wiki). Kept low so
/// Wikipedia-attested candidates still win ranking ties.
const AVRO_FREQUENCY: u64 = 1;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var data_exe: ?[]const u8 = null;
    var debug_db = false;
    var webz_copy = true;
    var include_avro = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--debug-db")) {
            debug_db = true;
        } else if (std.mem.eql(u8, a, "--no-webz-copy")) {
            webz_copy = false;
        } else if (std.mem.eql(u8, a, "--no-avro")) {
            include_avro = false;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown flag: {s}\n", .{a});
            return error.InvalidArguments;
        } else if (data_exe == null) {
            data_exe = a;
        } else {
            std.debug.print("unexpected arg: {s}\n", .{a});
            return error.InvalidArguments;
        }
    }

    const data = data_exe orelse blk: {
        if (try fileExists(io, "zig-out/bin/data")) break :blk "zig-out/bin/data";
        std.debug.print("error: pass path to `data` exe (or zig build prepare)\n", .{});
        return error.MissingDataExe;
    };

    try ensureSqlite3(gpa, io);
    try needFile(io, EXPORT_ID ++ "/dictionary.csv", "run: zig build export");
    try needFile(io, EXPORT_ID ++ "/bigrams.csv", "run: zig build export");
    try needFile(io, EXPORT_ID ++ "/trigrams.csv", "run: zig build export");
    try needFile(io, SEED, "missing confusion seed");
    try needFile(io, SCHEMA_ID, "missing sqlite schema");

    const dict_id = if (include_avro) DICT_PREPARED_ID else EXPORT_ID ++ "/dictionary.csv";
    if (include_avro) {
        try needFile(io, AVRO_DICT, "convert Avro Dictionary.json → dictionary_macos.csv");
        std.debug.print("\n==> [0/5] Merge Avro lexicon into Wikipedia dictionary\n", .{});
        const stats = try mergeAvroDictionary(gpa, io, .{
            .wiki_csv = EXPORT_ID ++ "/dictionary.csv",
            .avro_csv = AVRO_DICT,
            .out_csv = DICT_PREPARED_ID,
            .id_mode = true,
        });
        std.debug.print(
            "    wiki={d} + avro_new={d} → {d} words ({s})\n",
            .{ stats.wiki_count, stats.avro_added, stats.total, DICT_PREPARED_ID },
        );
    } else {
        std.debug.print("\n==> [0/5] skip Avro merge (--no-avro)\n", .{});
    }

    // --- Product spell.db (id-keyed) ---
    std.debug.print("\n==> [1/5] SymSpell deletes (export_id, word_id mode)\n", .{});
    try runData(gpa, io, data, &.{ "--symspell-deletes", dict_id });
    try moveFile(io, "deletes.csv", EXPORT_ID ++ "/deletes.csv");

    std.debug.print("\n==> [2/5] Mine confusion weights\n", .{});
    try runData(gpa, io, data, &.{ "--mine-confusions", dict_id, SEED });
    try moveFile(io, "confusions.csv", EXPORT_ID ++ "/confusions.csv");
    if (try fileExists(io, "confusions_mined.csv")) {
        try moveFile(io, "confusions_mined.csv", EXPORT_ID ++ "/confusions_mined.csv");
    }

    std.debug.print("\n==> [3/5] Assemble {s} via sqlite3\n", .{SPELL_DB});
    try assembleIdDb(gpa, io, dict_id);

    if (webz_copy) {
        std.debug.print("\n==> [4/5] Copy {s} → {s}\n", .{ SPELL_DB, WEBZ_DEFAULT_DB });
        try copyToWebz(io);
    } else {
        std.debug.print("\n==> [4/5] skip webz copy (--no-webz-copy)\n", .{});
    }

    if (debug_db) {
        std.debug.print("\n==> [5/5] --debug-db: assemble {s}\n", .{SPELL_DEBUG_DB});
        try needFile(io, EXPORT_DEBUG ++ "/dictionary.csv", "run: zig build export (writes export/)");
        try needFile(io, EXPORT_DEBUG ++ "/bigrams.csv", "run: zig build export");
        try needFile(io, EXPORT_DEBUG ++ "/trigrams.csv", "run: zig build export");
        try needFile(io, SCHEMA_DEBUG, "missing debug sqlite schema");

        const dict_debug = if (include_avro) DICT_PREPARED_DEBUG else EXPORT_DEBUG ++ "/dictionary.csv";
        if (include_avro) {
            std.debug.print("    Merge Avro into debug dictionary…\n", .{});
            const stats = try mergeAvroDictionary(gpa, io, .{
                .wiki_csv = EXPORT_DEBUG ++ "/dictionary.csv",
                .avro_csv = AVRO_DICT,
                .out_csv = DICT_PREPARED_DEBUG,
                .id_mode = false,
            });
            std.debug.print(
                "    wiki={d} + avro_new={d} → {d} words\n",
                .{ stats.wiki_count, stats.avro_added, stats.total },
            );
        }

        std.debug.print("    SymSpell deletes (text mode) — large!\n", .{});
        try runData(gpa, io, data, &.{ "--symspell-deletes", dict_debug });
        try moveFile(io, "deletes.csv", EXPORT_DEBUG ++ "/deletes.csv");
        try assembleDebugDb(gpa, io, dict_debug);
    } else {
        std.debug.print("\n==> [5/5] skip spell_debug.db (pass --debug-db to build it)\n", .{});
    }

    std.debug.print("\n==> prepare done → {s}\n", .{SPELL_DB});
}

const MergeStats = struct {
    wiki_count: usize,
    avro_added: usize,
    total: usize,
};

const MergeOptions = struct {
    wiki_csv: []const u8,
    avro_csv: []const u8,
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
        var in_file = try Io.Dir.cwd().openFile(io, opts.avro_csv, .{});
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

            const word = stripCsvQuotes(line);
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

fn assembleIdDb(gpa: std.mem.Allocator, io: Io, dictionary_csv: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, SPELL_DB) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    // sqlite3 .import needs a literal path; build the script with the chosen CSV.
    var script_buf: std.ArrayList(u8) = .empty;
    defer script_buf.deinit(gpa);
    try script_buf.print(gpa,
        \\.echo off
        \\.timer on
        \\.print '→ creating schema…'
        \\.read src/queries/10_sqlite_schema_id.sql
        \\.print '→ importing dictionary…'
        \\.mode csv
        \\.import --skip 1 '{s}' dictionary
        \\.print '→ importing deletes (largest step)…'
        \\.import --skip 1 'export_id/deletes.csv' deletes
        \\.print '→ importing bigrams…'
        \\.import --skip 1 'export_id/bigrams.csv' bigrams
        \\.print '→ importing trigrams…'
        \\.import --skip 1 'export_id/trigrams.csv' trigrams
        \\.print '→ importing confusions…'
        \\.import --skip 1 'export_id/confusions.csv' confusions
        \\.print '→ VACUUM + ANALYZE…'
        \\VACUUM;
        \\ANALYZE;
        \\.headers on
        \\.mode column
        \\SELECT 'dictionary' AS t, COUNT(*) AS n FROM dictionary
        \\UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
        \\UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
        \\UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams
        \\UNION ALL SELECT 'confusions', COUNT(*) FROM confusions;
        \\SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
        \\FROM pragma_page_count(), pragma_page_size();
        \\.print 'spell.db ready'
    , .{dictionary_csv});

    const script_path = ".prepare_spell_id.sql";
    try writeAll(io, script_path, script_buf.items);
    defer Io.Dir.cwd().deleteFile(io, script_path) catch {};

    try runSqlite3(gpa, io, SPELL_DB, script_path);
}

fn assembleDebugDb(gpa: std.mem.Allocator, io: Io, dictionary_csv: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, SPELL_DEBUG_DB) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    var script_buf: std.ArrayList(u8) = .empty;
    defer script_buf.deinit(gpa);
    try script_buf.print(gpa,
        \\.echo off
        \\.timer on
        \\.print '→ creating schema…'
        \\.read src/queries/07_sqlite_schema.sql
        \\.print '→ importing dictionary…'
        \\.mode csv
        \\.import --skip 1 '{s}' dictionary
        \\.print '→ importing deletes (very large for debug)…'
        \\.import --skip 1 'export/deletes.csv' deletes
        \\.print '→ importing bigrams…'
        \\.import --skip 1 'export/bigrams.csv' bigrams
        \\.print '→ importing trigrams…'
        \\.import --skip 1 'export/trigrams.csv' trigrams
        \\.print '→ VACUUM + ANALYZE…'
        \\VACUUM;
        \\ANALYZE;
        \\.headers on
        \\.mode column
        \\SELECT 'dictionary' AS t, COUNT(*) AS n FROM dictionary
        \\UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
        \\UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
        \\UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;
        \\.print 'spell_debug.db ready'
    , .{dictionary_csv});

    const script_path = ".prepare_spell_debug.sql";
    try writeAll(io, script_path, script_buf.items);
    defer Io.Dir.cwd().deleteFile(io, script_path) catch {};

    try runSqlite3(gpa, io, SPELL_DEBUG_DB, script_path);
}

fn copyToWebz(io: Io) !void {
    const dest_rel = WEBZ_DEFAULT_DB;
    // Ensure parent path exists (createDirPath on parent dir).
    try Io.Dir.cwd().createDirPath(io, "../../platforms/webz/zig-out/data/db");
    try Io.Dir.cwd().copyFile(SPELL_DB, Io.Dir.cwd(), dest_rel, io, .{
        .replace = true,
        .make_path = true,
    });
}

fn runSqlite3(gpa: std.mem.Allocator, io: Io, db_path: []const u8, script_path: []const u8) !void {
    _ = gpa;
    const script_file = try Io.Dir.cwd().openFile(io, script_path, .{});
    // Ownership transferred into spawn stdin; wait before return.
    var child = try process.spawn(io, .{
        .argv = &.{ "sqlite3", db_path },
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

fn ensureSqlite3(gpa: std.mem.Allocator, io: Io) !void {
    const result = process.run(gpa, io, .{
        .argv = &.{ "sqlite3", "--version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch {
        std.debug.print("error: sqlite3 not found on PATH\n", .{});
        return error.SqliteNotFound;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("error: sqlite3 --version failed\n", .{});
        return error.SqliteNotFound;
    }
    const ver = std.mem.trim(u8, result.stdout, " \t\r\n");
    std.debug.print("==> sqlite3: {s}\n", .{ver});
}

fn needFile(io: Io, path: []const u8, hint: []const u8) !void {
    if (!try fileExists(io, path)) {
        std.debug.print("error: missing {s}\n  {s}\n", .{ path, hint });
        return error.MissingFile;
    }
}

fn fileExists(io: Io, path: []const u8) !bool {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    f.close(io);
    return true;
}

fn moveFile(io: Io, src: []const u8, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, dest) catch {};
    try cwd.rename(src, cwd, dest, io);
}

fn writeAll(io: Io, path: []const u8, contents: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
}
