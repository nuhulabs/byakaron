//! Assemble `Byakaron.db` from `export` CSVs (through `zx.Db`, see build/sql.zig).
//!
//! Every path is explicit so `zig build db` can run this as a cached step:
//!
//!   prepare --data <data exe> --schema <schema.sql>
//!           --export <export_id dir> --seed <confusions_seed.csv>
//!           --work <scratch dir> --out <Byakaron.db>
//!           [--avro <words.txt>] [--debug]
//!
//! With `--avro`, Avro IME words (one per line) are appended to the Wikipedia
//! dictionary (synthetic frequency 1) before SymSpell / import. `--debug`
//! builds the text-keyed debug DB from `export/` (no confusions table).

const std = @import("std");
const Io = std.Io;
const process = std.process;
const sql = @import("sql");

/// Frequency assigned to Avro-only lemmas (unattested in wiki). Kept low so
/// Wikipedia-attested candidates still win ranking ties.
const AVRO_FREQUENCY: u64 = 1;

const Args = struct {
    data: []const u8,
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
        inline for (.{ "data", "schema", "export", "seed", "work", "out", "avro" }) |name| {
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
        .schema = undefined,
        .@"export" = undefined,
        .seed = undefined,
        .work = undefined,
        .out = undefined,
        .avro = parsed.avro,
        .debug = parsed.debug,
    };
    inline for (.{ "data", "schema", "export", "seed", "work", "out" }) |name| {
        @field(args, name) = @field(parsed, name) orelse {
            std.debug.print("error: missing --{s}\n", .{name});
            return error.InvalidArguments;
        };
    }

    // Four stages; the `data` runs below report into them via ZIG_PROGRESS.
    const progress = std.Progress.start(io, .{ .root_name = "prepare", .estimated_total_items = 4 });
    defer progress.end();

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, args.work);
    const exp = args.@"export";
    const id_mode = !args.debug;

    var dictionary = try std.fs.path.join(arena, &.{ exp, "dictionary.csv" });
    if (args.avro) |avro| {
        const stage = progress.start("merge Avro lexicon", 0);
        defer stage.end();
        const merged = try std.fs.path.join(arena, &.{ args.work, "dictionary_prepared.csv" });
        _ = try mergeAvroDictionary(gpa, io, .{
            .wiki_csv = dictionary,
            .avro_words = avro,
            .out_csv = merged,
            .id_mode = id_mode,
        });
        dictionary = merged;
    }
    progress.completeOne();

    const deletes = try std.fs.path.join(arena, &.{ args.work, "deletes.csv" });
    try runData(gpa, io, args.data, &.{ "--symspell-deletes", dictionary, "--out", deletes }, progress);
    progress.completeOne();

    var confusions: ?[]const u8 = null;
    if (id_mode) {
        const c = try std.fs.path.join(arena, &.{ args.work, "confusions.csv" });
        const mined = try std.fs.path.join(arena, &.{ args.work, "confusions_mined.csv" });
        try runData(gpa, io, args.data, &.{ "--mine-confusions", dictionary, args.seed, "--out", c, "--out-mined", mined }, progress);
        confusions = c;
    }
    progress.completeOne();

    {
        const stage = progress.start("assemble Byakaron.db", 0);
        defer stage.end();
        try assemble(gpa, io, args, .{
            .dictionary = dictionary,
            .deletes = deletes,
            .bigrams = try std.fs.path.join(arena, &.{ exp, "bigrams.csv" }),
            .trigrams = try std.fs.path.join(arena, &.{ exp, "trigrams.csv" }),
            .confusions = confusions,
        });
    }
    progress.completeOne();
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
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try sql.open(gpa, io, args.out, .read_write);
    defer db.deinit();

    const schema = try Io.Dir.cwd().readFileAlloc(io, args.schema, arena, .limited(1024 * 1024));
    try sql.exec(arena, db, schema);

    try sql.run(db, "BEGIN", .{});
    try importCsv(gpa, io, db, "dictionary", t.dictionary);
    try importCsv(gpa, io, db, "deletes", t.deletes);
    try importCsv(gpa, io, db, "bigrams", t.bigrams);
    try importCsv(gpa, io, db, "trigrams", t.trigrams);
    if (t.confusions) |c| try importCsv(gpa, io, db, "confusions", c);
    try sql.run(db, "COMMIT", .{});

    try sql.run(db, "VACUUM", .{});
    try sql.run(db, "ANALYZE", .{});
    try sql.makeReadable(io, args.out);
}

/// Rows per INSERT. ziex prepares each statement it runs, so one row per
/// statement would re-parse the INSERT for every row.
const batch_rows = 512;

/// Like the sqlite3 shell's `.import --skip 1 <csv> <table>` into an existing
/// table: the header line is skipped and every field is bound as text, so
/// column affinity converts numbers exactly as `.import` does.
fn importCsv(gpa: std.mem.Allocator, io: Io, db: sql.Db, table: []const u8, path: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var csv: Csv = .{ .in = &reader.interface };

    // Header gives the column count.
    var fields: std.ArrayList([]const u8) = .empty;
    if (!try csv.record(arena, arena, &fields)) return;
    const columns = fields.items.len;
    if (columns == 0) return error.InvalidCsv;

    var full: ?sql.Db.Statement = null;
    defer if (full) |*st| st.deinit();

    var values: std.ArrayList(sql.Value) = .empty;
    var batch: std.heap.ArenaAllocator = .init(gpa);
    defer batch.deinit();
    var rows: usize = 0;
    var line: usize = 1;
    while (true) {
        fields.clearRetainingCapacity();
        const more = try csv.record(batch.allocator(), arena, &fields);
        if (more) {
            line += 1;
            if (fields.items.len == 1 and fields.items[0].len == 0) continue; // blank line
            if (fields.items.len != columns) {
                std.debug.print("error: {s}:{d}: expected {d} fields, got {d}\n", .{ path, line, columns, fields.items.len });
                return error.InvalidCsv;
            }
            for (fields.items) |f| try values.append(arena, .{ .text = f });
            rows += 1;
        }
        if (rows == batch_rows or (!more and rows > 0)) {
            const bindings: sql.Db.Bindings = .fromPositional(values.items);
            if (rows == batch_rows) {
                if (full == null) full = try db.prepare(try insertSql(arena, table, columns, batch_rows));
                _ = try full.?.run(bindings);
            } else {
                try sql.run(db, try insertSql(arena, table, columns, rows), bindings);
            }
            values.clearRetainingCapacity();
            _ = batch.reset(.retain_capacity);
            rows = 0;
        }
        if (!more) break;
    }
}

fn insertSql(arena: std.mem.Allocator, table: []const u8, columns: usize, rows: usize) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print("INSERT INTO \"{s}\" VALUES ", .{table});
    for (0..rows) |r| {
        try w.writer.writeAll(if (r == 0) "(" else ",(");
        for (0..columns) |c| try w.writer.writeAll(if (c == 0) "?" else ",?");
        try w.writer.writeByte(')');
    }
    return w.written();
}

/// RFC 4180 records: `"` quotes a field, `""` is a literal quote, and a quoted
/// field may span lines. Accepts `\n` or `\r\n` line ends.
const Csv = struct {
    in: *Io.Reader,

    /// Appends the next record's fields (bytes in `bytes`, the list grown with
    /// `list`); false at end of input.
    fn record(self: *Csv, bytes: std.mem.Allocator, list: std.mem.Allocator, fields: *std.ArrayList([]const u8)) !bool {
        var field: std.ArrayList(u8) = .empty;
        var quoted = false;
        var any = false;
        while (true) {
            const c = self.in.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (!any) return false;
                    try fields.append(list, field.items);
                    return true;
                },
                else => |e| return e,
            };
            any = true;
            if (quoted) {
                if (c != '"') {
                    try field.append(bytes, c);
                } else if ((self.in.peekByte() catch 0) == '"') {
                    self.in.toss(1);
                    try field.append(bytes, '"');
                } else quoted = false;
                continue;
            }
            switch (c) {
                '"' => quoted = true,
                ',' => {
                    try fields.append(list, field.items);
                    field = .empty;
                },
                '\r' => {},
                '\n' => {
                    try fields.append(list, field.items);
                    return true;
                },
                else => try field.append(bytes, c),
            }
        }
    }
};

test Csv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed("id,word\r\n1,\"a,\"\"b\"\"\"\n2,c");
    var csv: Csv = .{ .in = &in };
    var f: std.ArrayList([]const u8) = .empty;
    try std.testing.expect(try csv.record(arena.allocator(), arena.allocator(), &f));
    f.clearRetainingCapacity();
    try std.testing.expect(try csv.record(arena.allocator(), arena.allocator(), &f));
    try std.testing.expectEqualStrings("a,\"b\"", f.items[1]);
    f.clearRetainingCapacity();
    try std.testing.expect(try csv.record(arena.allocator(), arena.allocator(), &f));
    try std.testing.expectEqualStrings("c", f.items[1]);
    f.clearRetainingCapacity();
    try std.testing.expect(!try csv.record(arena.allocator(), arena.allocator(), &f));
}

fn runData(gpa: std.mem.Allocator, io: Io, data_exe: []const u8, extra: []const []const u8, progress: std.Progress.Node) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, data_exe);
    try argv.appendSlice(gpa, extra);

    var child = try process.spawn(io, .{
        .argv = argv.items,
        .progress_node = progress,
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
