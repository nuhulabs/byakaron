//! Assemble `spell.db` from `export_id/` CSVs via the `sqlite3` CLI.
//!
//!   zig build export            # once (word_triplets → CSVs)
//!   zig build prepare           # SymSpell + confusions + sqlite3 → spell.db
//!   zig build prepare -- --debug-db
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var data_exe: ?[]const u8 = null;
    var debug_db = false;
    var webz_copy = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--debug-db")) {
            debug_db = true;
        } else if (std.mem.eql(u8, a, "--no-webz-copy")) {
            webz_copy = false;
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

    // --- Product spell.db (id-keyed) ---
    std.debug.print("\n==> [1/5] SymSpell deletes (export_id, word_id mode)\n", .{});
    try runData(gpa, io, data, &.{ "--symspell-deletes", EXPORT_ID ++ "/dictionary.csv" });
    try moveFile(io, "deletes.csv", EXPORT_ID ++ "/deletes.csv");

    std.debug.print("\n==> [2/5] Mine confusion weights\n", .{});
    try runData(gpa, io, data, &.{ "--mine-confusions", EXPORT_ID ++ "/dictionary.csv", SEED });
    try moveFile(io, "confusions.csv", EXPORT_ID ++ "/confusions.csv");
    if (try fileExists(io, "confusions_mined.csv")) {
        try moveFile(io, "confusions_mined.csv", EXPORT_ID ++ "/confusions_mined.csv");
    }

    std.debug.print("\n==> [3/5] Assemble {s} via sqlite3\n", .{SPELL_DB});
    try assembleIdDb(gpa, io);

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

        std.debug.print("    SymSpell deletes (text mode) — large!\n", .{});
        try runData(gpa, io, data, &.{ "--symspell-deletes", EXPORT_DEBUG ++ "/dictionary.csv" });
        try moveFile(io, "deletes.csv", EXPORT_DEBUG ++ "/deletes.csv");
        try assembleDebugDb(gpa, io);
    } else {
        std.debug.print("\n==> [5/5] skip spell_debug.db (pass --debug-db to build it)\n", .{});
    }

    std.debug.print("\n==> prepare done → {s}\n", .{SPELL_DB});
}

fn assembleIdDb(gpa: std.mem.Allocator, io: Io) !void {
    Io.Dir.cwd().deleteFile(io, SPELL_DB) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const script =
        \\.echo off
        \\.timer on
        \\.print '→ creating schema…'
        \\.read src/queries/10_sqlite_schema_id.sql
        \\.print '→ importing dictionary…'
        \\.mode csv
        \\.import --skip 1 'export_id/dictionary.csv' dictionary
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
    ;

    const script_path = ".prepare_spell_id.sql";
    try writeAll(io, script_path, script);
    defer Io.Dir.cwd().deleteFile(io, script_path) catch {};

    try runSqlite3(gpa, io, SPELL_DB, script_path);
}

fn assembleDebugDb(gpa: std.mem.Allocator, io: Io) !void {
    Io.Dir.cwd().deleteFile(io, SPELL_DEBUG_DB) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    const script =
        \\.echo off
        \\.timer on
        \\.print '→ creating schema…'
        \\.read src/queries/07_sqlite_schema.sql
        \\.print '→ importing dictionary…'
        \\.mode csv
        \\.import --skip 1 'export/dictionary.csv' dictionary
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
    ;

    const script_path = ".prepare_spell_debug.sql";
    try writeAll(io, script_path, script);
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
