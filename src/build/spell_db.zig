//! Build-time spell.db tools, run by `zig build db` / `zig build d1`.
//!
//!   spell_db trim <spell.db> <words> <out.db>
//!   spell_db d1 <spell.db> <out-dir>
//!   spell_db sync <from-dir> <to-dir>
//!
//! - `trim`: a copy of spell.db with only the `words` most frequent dictionary
//!   words, their delete keys, and the bigrams/trigrams between them. Same
//!   schema, so src/Spell/Sqlite.zig reads it as is.
//! - `d1`: spell.db as Cloudflare D1 migrations (`wrangler d1 migrations apply`):
//!   `0000` drops and recreates every table, the data files insert the rows in
//!   statements under D1's 100 KB limit, and the last file creates the indexes.
//!   Every name carries a hash of the contents, so a changed spell.db is a new
//!   set of migrations that wrangler applies from scratch. Each data file first
//!   deletes the rows it inserts, so a failed migration can simply be rerun.
//! - `sync`: make `to-dir` hold exactly the `.sql` files of `from-dir`, so an
//!   older set never lingers next to the current one in zig-out/d1/.

const std = @import("std");
const Io = std.Io;

/// D1 rejects statements over 100 KB.
const max_statement = 64 * 1024;
/// One migration is one D1 query request; keep each well inside its time limit.
const max_file = 4 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len == 5 and std.mem.eql(u8, args[1], "trim")) {
        const words = try std.fmt.parseInt(u32, args[3], 10);
        return trim(arena, io, args[2], words, args[4]);
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "d1")) return d1(arena, io, args[2], args[3]);
    if (args.len == 4 and std.mem.eql(u8, args[1], "sync")) return sync(arena, io, args[2], args[3]);
    std.debug.print(
        \\usage: {s} trim <spell.db> <words> <out.db>
        \\       {s} d1 <spell.db> <out-dir>
        \\       {s} sync <from-dir> <to-dir>
        \\
    , .{ args[0], args[0], args[0] });
    return error.InvalidArguments;
}

fn trim(arena: std.mem.Allocator, io: Io, src: []const u8, words: u32, out: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, out) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const db = try open(arena, out, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    defer _ = sqlite3_close(db);

    try exec(arena, db, try std.fmt.allocPrint(arena, "ATTACH {f} AS src", .{quoted(src)}));
    try exec(arena, db, "PRAGMA journal_mode = OFF");
    try exec(arena, db, "BEGIN");
    for (try column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) |sql| {
        try exec(arena, db, sql);
    }
    try exec(arena, db, try std.fmt.allocPrint(arena,
        \\INSERT INTO dictionary SELECT * FROM src.dictionary ORDER BY frequency DESC LIMIT {d};
        \\INSERT INTO deletes SELECT * FROM src.deletes WHERE word_id IN (SELECT id FROM dictionary);
        \\INSERT INTO bigrams SELECT * FROM src.bigrams
        \\    WHERE w1_id IN (SELECT id FROM dictionary) AND w2_id IN (SELECT id FROM dictionary);
        \\INSERT INTO trigrams SELECT * FROM src.trigrams
        \\    WHERE w1_id IN (SELECT id FROM dictionary) AND w2_id IN (SELECT id FROM dictionary)
        \\    AND w3_id IN (SELECT id FROM dictionary);
        \\INSERT INTO confusions SELECT * FROM src.confusions;
    , .{words}));
    for (try column(arena, db, "SELECT sql FROM src.sqlite_master WHERE type = 'index' AND sql IS NOT NULL")) |sql| {
        try exec(arena, db, sql);
    }
    try exec(arena, db, "COMMIT");
    try exec(arena, db, "DETACH src");
    try exec(arena, db, "ANALYZE");
}

fn d1(arena: std.mem.Allocator, io: Io, src: []const u8, out_dir: []const u8) !void {
    const db = try open(arena, src, SQLITE_OPEN_READONLY);
    defer _ = sqlite3_close(db);

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    var dir = try cwd.openDir(io, out_dir, .{});
    defer dir.close(io);

    var files: Files = .{ .arena = arena, .io = io, .dir = dir };

    // Application tables only; sqlite_* (e.g. sqlite_stat1) are SQLite internals D1 manages.
    const tables = try column(arena, db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
    for (tables) |t| try files.print("DROP TABLE IF EXISTS {f};\n", .{quoted(t)});
    for (try column(arena, db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")) |sql| {
        try files.print("{s};\n", .{sql});
    }
    try files.next();

    for (tables) |t| {
        // The rowid (or its INTEGER PRIMARY KEY alias) is inserted explicitly, so
        // `DELETE … WHERE rowid >= first` undoes a partly applied file.
        const pk = try column(arena, db, try std.fmt.allocPrint(arena,
            \\SELECT name FROM pragma_table_info({f}) WHERE pk = 1 AND upper(type) = 'INTEGER'
            \\    AND (SELECT count(*) FROM pragma_table_info({f}) WHERE pk > 0) = 1
        , .{ quoted(t), quoted(t) }));
        const cols = try column(arena, db, try std.fmt.allocPrint(arena, "SELECT name FROM pragma_table_info({f}) ORDER BY cid", .{quoted(t)}));

        var head: Io.Writer.Allocating = .init(arena);
        var select: Io.Writer.Allocating = .init(arena);
        try head.writer.print("INSERT INTO {f} (", .{quotedIdent(t)});
        if (pk.len == 0) try head.writer.writeAll("rowid, ");
        try select.writer.writeAll("SELECT rowid, '(' || ");
        if (pk.len == 0) try select.writer.writeAll("rowid || ',' || ");
        for (cols, 0..) |c, i| {
            const sep = if (i == 0) "" else ", ";
            try head.writer.print("{s}{f}", .{ sep, quotedIdent(c) });
            try select.writer.print("{s}quote({f})", .{ if (i == 0) "" else " || ',' || ", quotedIdent(c) });
        }
        try head.writer.writeAll(") VALUES ");
        try select.writer.print(" || ')' FROM {f} ORDER BY rowid", .{quotedIdent(t)});
        const rowid = if (pk.len == 0) "rowid" else pk[0];

        const stmt = try prepare(db, select.written());
        defer _ = sqlite3_finalize(stmt);
        var in_statement: usize = 0; // bytes of the open INSERT, 0 = none
        var started = false; // this table has rows in the current file
        while (try step(db, stmt)) {
            const id = sqlite3_column_int64(stmt, 0);
            const row = text(stmt, 1);
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

    for (try column(arena, db, "SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name")) |sql| {
        try files.print("{s};\n", .{sql});
    }
    try files.writeAll("PRAGMA optimize;\n");
    try files.next();

    // Name every file after the whole set's hash.
    const hash = files.hash.final();
    for (0..files.count) |i| {
        const tmp = try std.fmt.allocPrint(arena, "{d:0>4}.tmp", .{i});
        const name = try std.fmt.allocPrint(arena, "{d:0>4}_spell_{x:0>16}.sql", .{ i, hash });
        try dir.rename(tmp, dir, name, io);
    }
}

/// The migration files being written, `NNNN.tmp` until the set is complete.
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

    /// Close the current file; the next write starts a new one.
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

    // Names carry the content hash, so a file already there is up to date.
    var wit = want.keyIterator();
    while (wit.next()) |name| {
        if (have.contains(name.*)) continue;
        try src.copyFile(name.*, dst, name.*, io, .{});
    }
}

/// A string as an SQL literal.
fn quoted(s: []const u8) Quoted {
    return .{ .s = s, .q = '\'' };
}

/// A name as an SQL identifier.
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

fn open(arena: std.mem.Allocator, path: []const u8, flags: c_int) !*sqlite3 {
    var db: ?*sqlite3 = null;
    if (sqlite3_open_v2(try arena.dupeSentinel(u8, path, 0), &db, flags, null) != SQLITE_OK) {
        std.debug.print("error: cannot open {s}: {s}\n", .{ path, sqlite3_errmsg(db) });
        return error.SqliteOpenFailed;
    }
    return db.?;
}

fn exec(arena: std.mem.Allocator, db: *sqlite3, sql: []const u8) !void {
    var err: ?[*:0]u8 = null;
    if (sqlite3_exec(db, try arena.dupeSentinel(u8, sql, 0), null, null, &err) != SQLITE_OK) {
        std.debug.print("error: {s}\n  {s}\n", .{ err orelse sqlite3_errmsg(db), sql });
        return error.SqliteExecFailed;
    }
}

fn prepare(db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null) != SQLITE_OK) {
        std.debug.print("error: {s}\n  {s}\n", .{ sqlite3_errmsg(db), sql });
        return error.SqlitePrepareFailed;
    }
    return stmt.?;
}

/// Advance `stmt`: true while there is a row.
fn step(db: *sqlite3, stmt: *sqlite3_stmt) !bool {
    return switch (sqlite3_step(stmt)) {
        SQLITE_ROW => true,
        SQLITE_DONE => false,
        else => {
            std.debug.print("error: {s}\n", .{sqlite3_errmsg(db)});
            return error.SqliteStepFailed;
        },
    };
}

fn text(stmt: *sqlite3_stmt, col: c_int) []const u8 {
    const ptr = sqlite3_column_text(stmt, col) orelse return "";
    return ptr[0..@intCast(sqlite3_column_bytes(stmt, col))];
}

/// All values of the first column of `sql`, as text.
fn column(arena: std.mem.Allocator, db: *sqlite3, sql: []const u8) ![]const []const u8 {
    const stmt = try prepare(db, sql);
    defer _ = sqlite3_finalize(stmt);
    var out: std.ArrayList([]const u8) = .empty;
    while (try step(db, stmt)) try out.append(arena, try arena.dupe(u8, text(stmt, 0)));
    return out.items;
}

// ── sqlite3.h (amalgamation compiled in by build.zig) ───────────────────────

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY = 0x00000001;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*]const u8, len: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, col: c_int) i64;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, col: c_int) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
