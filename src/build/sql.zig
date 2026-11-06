//! `zx.Db` (ziex's bundled SQLite) for the host build tools: `lexicon`,
//! `spell_db` and `prepare`. Opens one connection, so `ATTACH` and `PRAGMA`s
//! hold for every later statement, and adds what those tools need on top:
//! multi-statement scripts and first-column queries.

const std = @import("std");
const zx = @import("zx");

pub const Db = zx.Db;
pub const Value = zx.Db.Value;

pub const Mode = enum { read_only, read_write };

pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, mode: Mode) !Db {
    return Db.Sqlite.open(gpa, io, path, .{
        .readonly = mode == .read_only,
        .create = mode == .read_write,
        // One connection: a pool would put `ATTACH` / `PRAGMA` on another
        // connection than the statements after it, and forces WAL.
        .max_pool_size = 1,
    }) catch |err| {
        std.debug.print("error: cannot open {s} ({t})\n", .{ path, err });
        return err;
    };
}

/// ziex builds SQLite with `SQLITE_DEFAULT_FILE_PERMISSIONS=0600`; a database
/// that gets installed or packaged (Byakaron.db) must stay world-readable.
pub fn makeReadable(io: std.Io, path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return;
    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o644), .{});
}

/// Runs one statement, printing it if it fails.
pub fn run(db: Db, sql: []const u8, args: anytype) !void {
    _ = db.run(sql, args) catch |err| {
        std.debug.print("error: {t}\n  {s}\n", .{ err, sql });
        return err;
    };
}

/// Runs every `;`-separated statement in `script` (comments and quotes
/// respected), like `sqlite3_exec`.
pub fn exec(arena: std.mem.Allocator, db: Db, script: []const u8) !void {
    var it: Statements = .{ .arena = arena, .src = script };
    while (try it.next()) |sql| try run(db, sql, .{});
}

/// The first column of every row of `sql`, as text (NULL as "").
pub fn column(arena: std.mem.Allocator, db: Db, sql: []const u8) ![]const []const u8 {
    const rows = db.all(arena, sql, .{}) catch |err| {
        std.debug.print("error: {t}\n  {s}\n", .{ err, sql });
        return err;
    };
    const out = try arena.alloc([]const u8, rows.len);
    for (rows, out) |row, *o| o.* = switch (row.fields[0].value) {
        .text, .blob => |t| t,
        .null => "",
        .integer => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
        .float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
        .boolean => |v| if (v) "1" else "0",
    };
    return out;
}

/// Splits a SQL script into statements, dropping `--` / `/* */` comments.
pub const Statements = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    pub fn next(self: *Statements) !?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const s = self.src;
        while (self.pos < s.len) {
            const c = s[self.pos];
            if (c == '-' and self.pos + 1 < s.len and s[self.pos + 1] == '-') {
                self.pos = std.mem.indexOfScalarPos(u8, s, self.pos, '\n') orelse s.len;
                continue;
            }
            if (c == '/' and self.pos + 1 < s.len and s[self.pos + 1] == '*') {
                const end = std.mem.indexOfPos(u8, s, self.pos + 2, "*/") orelse s.len;
                self.pos = @min(end + 2, s.len);
                try out.append(self.arena, ' ');
                continue;
            }
            if (c == '\'' or c == '"' or c == '`' or c == '[') {
                const close: u8 = if (c == '[') ']' else c;
                const end = std.mem.indexOfScalarPos(u8, s, self.pos + 1, close) orelse s.len - 1;
                try out.appendSlice(self.arena, s[self.pos .. end + 1]);
                self.pos = end + 1;
                continue;
            }
            self.pos += 1;
            if (c == ';') {
                const sql = std.mem.trim(u8, out.items, &std.ascii.whitespace);
                if (sql.len > 0) return sql;
                out.clearRetainingCapacity();
                continue;
            }
            try out.append(self.arena, c);
        }
        const sql = std.mem.trim(u8, out.items, &std.ascii.whitespace);
        return if (sql.len > 0) sql else null;
    }
};

test Statements {
    var it: Statements = .{ .arena = std.testing.allocator, .src =
        \\-- header; with a semicolon
        \\PRAGMA a = 1;
        \\CREATE TABLE t (x TEXT DEFAULT 'a;b'); /* c; */
        \\INSERT INTO t VALUES ('it''s;')
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    it.arena = arena.allocator();
    try std.testing.expectEqualStrings("PRAGMA a = 1", (try it.next()).?);
    try std.testing.expectEqualStrings("CREATE TABLE t (x TEXT DEFAULT 'a;b')", (try it.next()).?);
    try std.testing.expectEqualStrings("INSERT INTO t VALUES ('it''s;')", (try it.next()).?);
    try std.testing.expect(try it.next() == null);
}
