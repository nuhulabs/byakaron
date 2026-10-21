//! Aggregate `word_triplets.csv` → `export/` + `export_id/` CSVs (no Postgres / sqlite forge).
//!
//!   zig build export
//!   zig build export -- word_triplets_sample.csv --min-freq-id 5
//!
//! Single streaming pass with interned word ids; progress on stderr like `--wordtriplets`.

const std = @import("std");
const Io = std.Io;

const DEFAULT_INPUT = "word_triplets.csv";

/// Joins `zig build`'s progress tree via ZIG_PROGRESS.
var progress: std.Progress.Node = .none;
const DEFAULT_MIN_DEBUG: u64 = 2;
const DEFAULT_MIN_ID: u64 = 15;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var input: []const u8 = DEFAULT_INPUT;
    var min_debug: u64 = DEFAULT_MIN_DEBUG;
    var min_id: u64 = DEFAULT_MIN_ID;
    var export_debug_dir: []const u8 = "export";
    var export_id_dir: []const u8 = "export_id";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--min-freq-debug")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            min_debug = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--min-freq-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            min_id = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--export-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            export_debug_dir = args[i];
        } else if (std.mem.eql(u8, a, "--export-id-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            export_id_dir = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("unknown flag: {s}\n", .{a});
            return error.InvalidArguments;
        } else {
            input = a;
        }
    }

    progress = std.Progress.start(io, .{ .root_name = "export (MiB)" });
    defer progress.end();

    try runExport(gpa, io, .{
        .input = input,
        .min_debug = min_debug,
        .min_id = min_id,
        .export_debug_dir = export_debug_dir,
        .export_id_dir = export_id_dir,
    });
}

const Options = struct {
    input: []const u8,
    min_debug: u64,
    min_id: u64,
    export_debug_dir: []const u8,
    export_id_dir: []const u8,
};

const TriKey = struct {
    a: u32,
    b: u32,
    c: u32,

    fn hash(self: TriKey) u64 {
        var h: u64 = self.a;
        h = h *% 0x9E3779B97F4A7C15 +% self.b;
        h = h *% 0x9E3779B97F4A7C15 +% self.c;
        return h;
    }

    fn eql(x: TriKey, y: TriKey) bool {
        return x.a == y.a and x.b == y.b and x.c == y.c;
    }
};

const TriContext = struct {
    pub fn hash(_: TriContext, key: TriKey) u64 {
        return key.hash();
    }
    pub fn eql(_: TriContext, a: TriKey, b: TriKey) bool {
        return TriKey.eql(a, b);
    }
};

fn runExport(gpa: std.mem.Allocator, io: Io, opts: Options) !void {
    var in_file = try Io.Dir.cwd().openFile(io, opts.input, .{});
    defer in_file.close(io);
    var in_buf: [256 * 1024]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);
    const total_size: u64 = in_reader.getSize() catch 0;
    const in = &in_reader.interface;

    // Interned surface forms (stable for the whole run).
    var word_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer word_arena_state.deinit();
    const word_arena = word_arena_state.allocator();

    var word_to_id: std.StringHashMapUnmanaged(u32) = .empty;
    defer word_to_id.deinit(gpa);
    var id_to_word: std.ArrayListUnmanaged([]const u8) = .empty;
    defer id_to_word.deinit(gpa);
    var uni_counts: std.ArrayListUnmanaged(u64) = .empty;
    defer uni_counts.deinit(gpa);

    var bi_counts: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer bi_counts.deinit(gpa);

    var tri_counts: std.HashMapUnmanaged(TriKey, u64, TriContext, 80) = .empty;
    defer tri_counts.deinit(gpa);

    var row_count: u64 = 0;
    var last_report: u64 = 0;
    var header_checked = false;

    const intern = struct {
        fn call(
            gpa_: std.mem.Allocator,
            arena_: std.mem.Allocator,
            map: *std.StringHashMapUnmanaged(u32),
            words: *std.ArrayListUnmanaged([]const u8),
            counts: *std.ArrayListUnmanaged(u64),
            surface: []const u8,
        ) !u32 {
            const gop = try map.getOrPut(gpa_, surface);
            if (gop.found_existing) return gop.value_ptr.*;
            const owned = try arena_.dupe(u8, surface);
            gop.key_ptr.* = owned;
            const id: u32 = @intCast(words.items.len);
            gop.value_ptr.* = id;
            try words.append(gpa_, owned);
            try counts.append(gpa_, 0);
            return id;
        }
    }.call;

    const bumpUni = struct {
        fn call(counts: *std.ArrayListUnmanaged(u64), id: u32) void {
            counts.items[id] += 1;
        }
    }.call;

    const bumpBi = struct {
        fn call(map: *std.AutoHashMapUnmanaged(u64, u64), gpa_: std.mem.Allocator, a: u32, b: u32) !void {
            const key: u64 = (@as(u64, a) << 32) | @as(u64, b);
            const gop = try map.getOrPut(gpa_, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }.call;

    const bumpTri = struct {
        fn call(map: *std.HashMapUnmanaged(TriKey, u64, TriContext, 80), gpa_: std.mem.Allocator, a: u32, b: u32, c: u32) !void {
            const key: TriKey = .{ .a = a, .b = b, .c = c };
            const gop = try map.getOrPut(gpa_, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }.call;

    while (try in.takeDelimiter('\n')) |raw_line| {
        if (!header_checked) {
            header_checked = true;
            if (std.mem.startsWith(u8, raw_line, "value,")) continue;
        }

        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const parsed = parseTripletLine(line) orelse continue;
        const a = try intern(gpa, word_arena, &word_to_id, &id_to_word, &uni_counts, parsed.w1);
        const b = try intern(gpa, word_arena, &word_to_id, &id_to_word, &uni_counts, parsed.w2);
        const c = try intern(gpa, word_arena, &word_to_id, &id_to_word, &uni_counts, parsed.w3);

        bumpUni(&uni_counts, a);
        bumpUni(&uni_counts, b);
        bumpUni(&uni_counts, c);
        try bumpBi(&bi_counts, gpa, a, b);
        try bumpBi(&bi_counts, gpa, b, c);
        try bumpTri(&tri_counts, gpa, a, b, c);

        row_count += 1;
        if (row_count - last_report >= 500_000) {
            last_report = row_count;
            reportProgress(in_reader.pos, total_size, row_count, id_to_word.items.len, bi_counts.count(), tri_counts.count());
        }
    }

    reportProgress(in_reader.pos, total_size, row_count, id_to_word.items.len, bi_counts.count(), tri_counts.count());

    try Io.Dir.cwd().createDirPath(io, opts.export_debug_dir);
    try Io.Dir.cwd().createDirPath(io, opts.export_id_dir);

    // try writeTextExports(gpa, io, opts, id_to_word.items, uni_counts.items, &bi_counts, &tri_counts);

    progress.setName("export: writing CSVs");
    try writeIdExports(gpa, io, opts, id_to_word.items, uni_counts.items, &bi_counts, &tri_counts);
}

const Triplet = struct { w1: []const u8, w2: []const u8, w3: []const u8 };

fn parseTripletLine(line: []const u8) ?Triplet {
    // Fast path: no quotes (typical Bangla rows).
    if (std.mem.indexOfScalar(u8, line, '"') == null) {
        const c1 = std.mem.indexOfScalar(u8, line, ',') orelse return null;
        const c2 = std.mem.indexOfScalarPos(u8, line, c1 + 1, ',') orelse return null;
        const w1 = line[0..c1];
        const w2 = line[c1 + 1 .. c2];
        const w3 = line[c2 + 1 ..];
        if (w1.len == 0 or w2.len == 0 or w3.len == 0) return null;
        return .{ .w1 = w1, .w2 = w2, .w3 = w3 };
    }

    // Quoted CSV fallback.
    var fields: [3][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < 3) {
        if (line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len) {
                if (line[i] == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            fields[n] = line[start..i];
            n += 1;
            if (i < line.len and line[i] == '"') i += 1;
            if (i < line.len and line[i] == ',') i += 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ',') : (i += 1) {}
            fields[n] = line[start..i];
            n += 1;
            if (i < line.len and line[i] == ',') i += 1;
        }
    }
    if (n != 3) return null;
    if (fields[0].len == 0 or fields[1].len == 0 or fields[2].len == 0) return null;
    return .{ .w1 = fields[0], .w2 = fields[1], .w3 = fields[2] };
}

const FreqRow = struct {
    id: u32,
    frequency: u64,
};

fn writeTextExports(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    words: []const []const u8,
    uni: []const u64,
    bi: *std.AutoHashMapUnmanaged(u64, u64),
    tri: *std.HashMapUnmanaged(TriKey, u64, TriContext, 80),
) !void {
    var dict_rows: std.ArrayListUnmanaged(FreqRow) = .empty;
    defer dict_rows.deinit(gpa);
    for (uni, 0..) |freq, id| {
        if (freq >= opts.min_debug) try dict_rows.append(gpa, .{ .id = @intCast(id), .frequency = freq });
    }
    std.mem.sort(FreqRow, dict_rows.items, {}, freqDesc);

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/dictionary.csv", .{opts.export_debug_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("word,frequency\n");
        for (dict_rows.items) |row| {
            try writeCsvField(out, words[row.id]);
            try out.print(",{d}\n", .{row.frequency});
        }
        try out.flush();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/bigrams.csv", .{opts.export_debug_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("w1,w2,frequency\n");

        var rows: std.ArrayListUnmanaged(struct { a: u32, b: u32, frequency: u64 }) = .empty;
        defer rows.deinit(gpa);
        var it = bi.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < opts.min_debug) continue;
            const key = e.key_ptr.*;
            try rows.append(gpa, .{
                .a = @intCast(key >> 32),
                .b = @intCast(key & 0xffff_ffff),
                .frequency = e.value_ptr.*,
            });
        }
        std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
            fn less(_: void, x: @TypeOf(rows.items[0]), y: @TypeOf(rows.items[0])) bool {
                return x.frequency > y.frequency;
            }
        }.less);
        for (rows.items) |row| {
            try writeCsvField(out, words[row.a]);
            try out.writeByte(',');
            try writeCsvField(out, words[row.b]);
            try out.print(",{d}\n", .{row.frequency});
        }
        try out.flush();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/trigrams.csv", .{opts.export_debug_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("w1,w2,w3,frequency\n");

        var rows: std.ArrayListUnmanaged(struct { a: u32, b: u32, c: u32, frequency: u64 }) = .empty;
        defer rows.deinit(gpa);
        var it = tri.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < opts.min_debug) continue;
            try rows.append(gpa, .{
                .a = e.key_ptr.a,
                .b = e.key_ptr.b,
                .c = e.key_ptr.c,
                .frequency = e.value_ptr.*,
            });
        }
        std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
            fn less(_: void, x: @TypeOf(rows.items[0]), y: @TypeOf(rows.items[0])) bool {
                return x.frequency > y.frequency;
            }
        }.less);
        for (rows.items) |row| {
            try writeCsvField(out, words[row.a]);
            try out.writeByte(',');
            try writeCsvField(out, words[row.b]);
            try out.writeByte(',');
            try writeCsvField(out, words[row.c]);
            try out.print(",{d}\n", .{row.frequency});
        }
        try out.flush();
    }
}

fn writeIdExports(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    words: []const []const u8,
    uni: []const u64,
    bi: *std.AutoHashMapUnmanaged(u64, u64),
    tri: *std.HashMapUnmanaged(TriKey, u64, TriContext, 80),
) !void {
    var dict_rows: std.ArrayListUnmanaged(FreqRow) = .empty;
    defer dict_rows.deinit(gpa);
    for (uni, 0..) |freq, id| {
        if (freq >= opts.min_id) try dict_rows.append(gpa, .{ .id = @intCast(id), .frequency = freq });
    }
    std.mem.sort(FreqRow, dict_rows.items, words, struct {
        fn less(w: []const []const u8, a: FreqRow, b: FreqRow) bool {
            if (a.frequency != b.frequency) return a.frequency > b.frequency;
            return std.mem.order(u8, w[a.id], w[b.id]) == .lt;
        }
    }.less);

    // old_id → dense export id (1..N)
    var remap: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer remap.deinit(gpa);
    for (dict_rows.items, 0..) |row, i| {
        try remap.put(gpa, row.id, @intCast(i + 1));
    }

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/dictionary.csv", .{opts.export_id_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("id,word,frequency\n");
        for (dict_rows.items, 0..) |row, i| {
            try out.print("{d},", .{i + 1});
            try writeCsvField(out, words[row.id]);
            try out.print(",{d}\n", .{row.frequency});
        }
        try out.flush();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/bigrams.csv", .{opts.export_id_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("w1_id,w2_id,frequency\n");

        var rows: std.ArrayListUnmanaged(struct { a: u32, b: u32, frequency: u64 }) = .empty;
        defer rows.deinit(gpa);
        var it = bi.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < opts.min_id) continue;
            const key = e.key_ptr.*;
            const oa: u32 = @intCast(key >> 32);
            const ob: u32 = @intCast(key & 0xffff_ffff);
            const na = remap.get(oa) orelse continue;
            const nb = remap.get(ob) orelse continue;
            try rows.append(gpa, .{ .a = na, .b = nb, .frequency = e.value_ptr.* });
        }
        std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
            fn less(_: void, x: @TypeOf(rows.items[0]), y: @TypeOf(rows.items[0])) bool {
                return x.frequency > y.frequency;
            }
        }.less);
        for (rows.items) |row| {
            try out.print("{d},{d},{d}\n", .{ row.a, row.b, row.frequency });
        }
        try out.flush();
    }

    {
        const path = try std.fmt.allocPrint(gpa, "{s}/trigrams.csv", .{opts.export_id_dir});
        defer gpa.free(path);
        var file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        const out = &writer.interface;
        try out.writeAll("w1_id,w2_id,w3_id,frequency\n");

        var rows: std.ArrayListUnmanaged(struct { a: u32, b: u32, c: u32, frequency: u64 }) = .empty;
        defer rows.deinit(gpa);
        var it = tri.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < opts.min_id) continue;
            const na = remap.get(e.key_ptr.a) orelse continue;
            const nb = remap.get(e.key_ptr.b) orelse continue;
            const nc = remap.get(e.key_ptr.c) orelse continue;
            try rows.append(gpa, .{ .a = na, .b = nb, .c = nc, .frequency = e.value_ptr.* });
        }
        std.mem.sort(@TypeOf(rows.items[0]), rows.items, {}, struct {
            fn less(_: void, x: @TypeOf(rows.items[0]), y: @TypeOf(rows.items[0])) bool {
                return x.frequency > y.frequency;
            }
        }.less);
        for (rows.items) |row| {
            try out.print("{d},{d},{d},{d}\n", .{ row.a, row.b, row.c, row.frequency });
        }
        try out.flush();
    }
}

fn freqDesc(_: void, a: FreqRow, b: FreqRow) bool {
    return a.frequency > b.frequency;
}

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

fn reportProgress(pos: u64, total: u64, rows: u64, words: usize, bigrams: u32, trigrams: u32) void {
    var buf: [96]u8 = undefined;
    progress.setName(std.fmt.bufPrint(&buf, "export: {d} rows, {d} words, {d} bigrams, {d} trigrams (MiB)", .{ rows, words, bigrams, trigrams }) catch "export (MiB)");
    progress.setEstimatedTotalItems(@intCast(total >> 20));
    progress.setCompletedItems(@intCast(pos >> 20));
}
