// spell_db trim <Byakaron.db> <words> <out.db>   keep the most frequent words
// spell_db pack <Byakaron.db> <out.db>           the smaller copy apps ship
// spell_db d1 <Byakaron.db> <out-dir>            write D1 migrations
// spell_db sync <from-dir> <to-dir>           mirror the .sql files

const std = @import("std");
const Io = std.Io;
const sql = @import("sql");

// D1 limits a statement to 100 KB, and runs each migration as one query.
const max_statement = 64 * 1024;
const max_file = 4 * 1024 * 1024;

var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    gpa = init.gpa;

    if (args.len == 5 and std.mem.eql(u8, args[1], "trim")) {
        const words = try std.fmt.parseInt(u32, args[3], 10);
        return trim(arena, io, args[2], words, args[4]);
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "pack")) return pack(arena, io, args[2], args[3]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "d1")) return d1(arena, io, args[2], args[3]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "sync")) return sync(arena, io, args[2], args[3]);
    std.debug.print(
        \\usage: {s} trim <Byakaron.db> <words> <out.db>
        \\       {s} pack <Byakaron.db> <out.db>
        \\       {s} d1 <Byakaron.db> <out-dir>
        \\       {s} sync <from-dir> <to-dir>
        \\
    , .{ args[0], args[0], args[0], args[0] });
    return error.InvalidArguments;
}

fn trim(arena: std.mem.Allocator, io: Io, src: []const u8, words: u32, out: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, out) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var db = try sql.open(gpa, io, out, .read_write);
    defer db.deinit();

    try sql.run(db, "ATTACH ? AS src", .{src});
    try sql.exec(arena, db, "PRAGMA journal_mode = OFF");
    try sql.exec(arena, db, "BEGIN");
    for (try sql.column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) |ddl| {
        try sql.exec(arena, db, ddl);
    }
    try sql.exec(arena, db, try std.fmt.allocPrint(arena,
        \\INSERT INTO dictionary SELECT * FROM src.dictionary ORDER BY frequency DESC LIMIT {d};
        \\INSERT INTO deletes SELECT * FROM src.deletes WHERE word_id IN (SELECT id FROM dictionary);
        \\INSERT INTO bigrams SELECT * FROM src.bigrams
        \\    WHERE w1_id IN (SELECT id FROM dictionary) AND w2_id IN (SELECT id FROM dictionary);
        \\INSERT INTO trigrams SELECT * FROM src.trigrams
        \\    WHERE w1_id IN (SELECT id FROM dictionary) AND w2_id IN (SELECT id FROM dictionary)
        \\    AND w3_id IN (SELECT id FROM dictionary);
        \\INSERT INTO confusions SELECT * FROM src.confusions;
    , .{words}));
    for (try sql.column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'index' AND sql IS NOT NULL")) |ddl| {
        try sql.exec(arena, db, ddl);
    }
    try sql.exec(arena, db, "COMMIT");
    try sql.exec(arena, db, "DETACH src");
    try sql.exec(arena, db, "ANALYZE");
    try sql.makeReadable(io, out);
}

/// The copy apps ship. `deletes` (the SymSpell keys) is 93% of Byakaron.db:
/// a rowid table plus `idx_deletes_key`, which stores every key a second time.
/// Here it is one WITHOUT ROWID b-tree on (delete_key, word_id) instead, and
/// everything else is copied as it is, so every other query plan is unchanged.
/// Same rows in the same order: word_id only rises with rowid, so the old
/// index already returned a key's rows in word_id order. ~45% smaller.
/// Not for `trim` or `d1`, which read rowids.
fn pack(arena: std.mem.Allocator, io: Io, src: []const u8, out: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, out) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var db = try sql.open(gpa, io, out, .read_write);
    defer db.deinit();

    try sql.run(db, "ATTACH ? AS src", .{src});
    try sql.exec(arena, db, "PRAGMA journal_mode = OFF");
    try sql.exec(arena, db, "BEGIN");
    const tables = try sql.column(arena, db, "SELECT name FROM src.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid");
    for (try sql.column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid"), tables) |ddl, t| {
        try sql.exec(arena, db, if (std.mem.eql(u8, t, "deletes"))
            \\CREATE TABLE deletes (
            \\    delete_key TEXT NOT NULL,
            \\    word_id INTEGER NOT NULL,
            \\    PRIMARY KEY (delete_key, word_id)
            \\) WITHOUT ROWID
        else
            ddl);
    }
    for (tables) |t| {
        // OR IGNORE: a repeated (key, word) pair would only repeat a candidate
        // the speller keeps once per word anyway.
        try sql.exec(arena, db, if (std.mem.eql(u8, t, "deletes"))
            "INSERT OR IGNORE INTO deletes SELECT delete_key, word_id FROM src.deletes ORDER BY delete_key, word_id"
        else
            try std.fmt.allocPrint(arena, "INSERT INTO {f} SELECT * FROM src.{f} ORDER BY rowid", .{ quotedIdent(t), quotedIdent(t) }));
    }
    for (try sql.column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'index' AND sql IS NOT NULL AND tbl_name <> 'deletes' ORDER BY rowid")) |ddl| {
        try sql.exec(arena, db, ddl);
    }
    try sql.exec(arena, db, "COMMIT");
    try sql.exec(arena, db, "DETACH src");
    try sql.exec(arena, db, "ANALYZE");
    try sql.makeReadable(io, out);
}

fn d1(arena: std.mem.Allocator, io: Io, src: []const u8, out_dir: []const u8) !void {
    var db = try sql.open(gpa, io, src, .read_only);
    defer db.deinit();

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    var dir = try cwd.openDir(io, out_dir, .{});
    defer dir.close(io);

    var files: Files = .{ .arena = arena, .io = io, .dir = dir };
    const tables = try sql.column(arena, db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    for (tables) |t| try files.print("DROP TABLE IF EXISTS {f};\n", .{quoted(t)});
    for (try sql.column(arena, db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) |ddl| {
        try files.print("{s};\n", .{ddl});
    }
    try files.next();

    for (tables) |t| {
        // Explicit rowids let each file start with `DELETE ... >= first row`,
        // so a migration that failed halfway can be rerun.
        const pk = try sql.column(arena, db, try std.fmt.allocPrint(arena,
            \\SELECT name FROM pragma_table_info({f}) WHERE pk = 1 AND upper(type) = 'INTEGER'
            \\    AND (SELECT count(*) FROM pragma_table_info({f}) WHERE pk > 0) = 1
        , .{ quoted(t), quoted(t) }));
        const cols = try sql.column(arena, db, try std.fmt.allocPrint(arena, "SELECT name FROM pragma_table_info({f}) ORDER BY cid", .{quoted(t)}));

        var head: Io.Writer.Allocating = .init(arena);
        var select: Io.Writer.Allocating = .init(arena);
        try head.writer.print("INSERT INTO {f} (", .{quotedIdent(t)});
        if (pk.len == 0) try head.writer.writeAll("rowid, ");
        try select.writer.writeAll("SELECT rowid AS id, '(' || ");
        if (pk.len == 0) try select.writer.writeAll("rowid || ',' || ");
        for (cols, 0..) |c, i| {
            const sep = if (i == 0) "" else ", ";
            try head.writer.print("{s}{f}", .{ sep, quotedIdent(c) });
            try select.writer.print("{s}quote({f})", .{ if (i == 0) "" else " || ',' || ", quotedIdent(c) });
        }
        try head.writer.writeAll(") VALUES ");
        try select.writer.print(" || ')' AS row FROM {f} ORDER BY rowid", .{quotedIdent(t)});
        const rowid = if (pk.len == 0) "rowid" else pk[0];

        var stmt = try db.prepare(select.written());
        defer stmt.deinit();
        var rows = try stmt.iterate(.{});
        defer rows.deinit();
        var in_statement: usize = 0;
        var started = false;
        while (try rows.next()) |r| {
            const id = r.int("id");
            const row = r.text("row");
            if (in_statement > 0 and (in_statement + row.len + 2 > max_statement or files.size + row.len + 2 > max_file)) {
                try files.writeAll(";\n");
                in_statement = 0;
                if (files.size > max_file - max_statement) {
                    try files.next();
                    started = false;
                }
            }
            if (!started) {
                try files.print("DELETE FROM {f} WHERE {f} >= {d};\n", .{ quotedIdent(t), quotedIdent(rowid), id });
                started = true;
            }
            if (in_statement == 0) {
                try files.writeAll(head.written());
                in_statement = head.written().len;
            } else {
                try files.writeAll(",");
                in_statement += 1;
            }
            try files.writeAll(row);
            in_statement += row.len;
        }
        if (in_statement > 0) try files.writeAll(";\n");
    }
    try files.next();

    for (try sql.column(arena, db, "SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name")) |ddl| {
        try files.print("{s};\n", .{ddl});
    }
    try files.writeAll("PRAGMA optimize;\n");
    try files.next();

    const hash = files.hash.final();
    for (0..files.count) |i| {
        const tmp = try std.fmt.allocPrint(arena, "{d:0>4}.tmp", .{i});
        const name = try std.fmt.allocPrint(arena, "{d:0>4}_spell_{x:0>16}.sql", .{ i, hash });
        try dir.rename(tmp, dir, name, io);
    }
}

const Files = struct {
    arena: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    count: usize = 0,
    file: ?Io.File = null,
    writer: Io.File.Writer = undefined,
    buf: [64 * 1024]u8 = undefined,
    size: usize = 0,
    hash: std.hash.Wyhash = .init(0),

    fn current(f: *Files) !*Io.Writer {
        if (f.file == null) {
            const name = try std.fmt.allocPrint(f.arena, "{d:0>4}.tmp", .{f.count});
            f.file = try f.dir.createFile(f.io, name, .{});
            f.writer = f.file.?.writer(f.io, &f.buf);
        }
        return &f.writer.interface;
    }

    fn writeAll(f: *Files, bytes: []const u8) !void {
        try (try f.current()).writeAll(bytes);
        f.hash.update(bytes);
        f.size += bytes.len;
    }

    fn print(f: *Files, comptime fmt: []const u8, args: anytype) !void {
        try f.writeAll(try std.fmt.allocPrint(f.arena, fmt, args));
    }

    fn next(f: *Files) !void {
        const file = f.file orelse return;
        try f.writer.interface.flush();
        file.close(f.io);
        f.file = null;
        f.size = 0;
        f.count += 1;
    }
};

fn sync(arena: std.mem.Allocator, io: Io, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var src = try cwd.openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    try cwd.createDirPath(io, to);
    var dst = try cwd.openDir(io, to, .{ .iterate = true });
    defer dst.close(io);

    var want: std.StringHashMapUnmanaged(void) = .empty;
    var it = src.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".sql")) continue;
        try want.put(arena, try arena.dupe(u8, e.name), {});
    }

    var stale: std.ArrayList([]const u8) = .empty;
    var have: std.StringHashMapUnmanaged(void) = .empty;
    var dit = dst.iterate();
    while (try dit.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".sql")) continue;
        const name = try arena.dupe(u8, e.name);
        if (want.contains(name)) try have.put(arena, name, {}) else try stale.append(arena, name);
    }
    for (stale.items) |name| try dst.deleteFile(io, name);

    var wit = want.keyIterator();
    while (wit.next()) |name| {
        if (have.contains(name.*)) continue;
        try src.copyFile(name.*, dst, name.*, io, .{});
    }
}

fn quoted(s: []const u8) Quoted {
    return .{ .s = s, .q = '\'' };
}

fn quotedIdent(s: []const u8) Quoted {
    return .{ .s = s, .q = '"' };
}

const Quoted = struct {
    s: []const u8,
    q: u8,

    pub fn format(self: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte(self.q);
        for (self.s) |c| {
            if (c == self.q) try w.writeByte(c);
            try w.writeByte(c);
        }
        try w.writeByte(self.q);
    }
};
