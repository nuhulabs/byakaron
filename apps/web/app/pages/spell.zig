//! Thin web façade over byakaron `src/` spell + autocomplete backends.
//!
//! Storage is the app database `zx.db`: Cloudflare D1 on the Workers build
//! (spell.db as migrations from `zig build d1`), and natively
//! `<install prefix>/db/spell.db` (built by `zig build db`) opened read-only by
//! main.zig. Backends are process-static (no heap) so hot-reload doesn't trip
//! leak checks.

const std = @import("std");
const zx = @import("zx");
const Spell = @import("spell");
const AutoComplete = @import("autocomplete");
const SpellSqlite = @import("spell_sqlite");
const AutoCompleteSqlite = @import("autocomplete_sqlite");
const AutoCompleteMem = @import("autocomplete_mem");

pub const Suggestion = Spell.Suggestion;
pub const TokenResult = Spell.TokenResult;
pub const AutoCompleteSuggestion = AutoComplete.Suggestion;

var spell_backend: SpellSqlite = undefined;
var spell_ready: bool = false;

var ac_sqlite_backend: AutoCompleteSqlite = undefined;
var ac_sqlite_ready: bool = false;

var ac_mem_backend: ?*AutoCompleteMem = null;

/// Opens spell.db read-only as `zx.db` on native targets. On wasm32-wasi ziex
/// already binds `zx.db` to the platform database (D1 on Cloudflare).
pub fn openLocalDb() !void {
    if (zx.platform.isWasm()) return;
    const allocator = std.heap.page_allocator;
    const root: []const u8 = if (std.c.getenv("ZIEX_ROOT_DIR")) |r| std.mem.span(r) else "zig-out";
    const path = try std.fs.path.join(allocator, &.{ root, "db", "spell.db" });
    std.Io.Dir.cwd().access(zx.io(), path, .{}) catch {
        std.log.warn("byakaron: no {s}; spell check is off (run `zig build db`)", .{path});
        return;
    };
    zx.db = zx.Db.Sqlite.open(allocator, zx.io(), path, .{
        .readonly = true,
        .create = false,
        .readwrite = false,
        // ziex's pooled mode forces `journal_mode=wal`, which a read-only
        // connection rejects; one serialized connection is plenty here.
        .max_pool_size = 1,
    }) catch |err| {
        std.log.err("byakaron: cannot open {s} ({t}); run `zig build db`", .{ path, err });
        return err;
    };
}

fn spellEngine() !*Spell {
    // Asked of zx.db: main.zig and the routes each compile their own copy of this file.
    if (zx.db.vtable == zx.Db.failing.vtable) return error.NoSpellDb;
    if (!spell_ready) {
        SpellSqlite.initBorrowedInto(&spell_backend, &zx.db);
        spell_ready = true;
    }
    return spell_backend.engine();
}

fn autoCompleteSqlite() *AutoComplete {
    if (!ac_sqlite_ready) {
        AutoCompleteSqlite.initBorrowedInto(&ac_sqlite_backend, &zx.db);
        ac_sqlite_ready = true;
    }
    return ac_sqlite_backend.autoComplete();
}

fn autoCompleteMem() *AutoComplete {
    if (ac_mem_backend == null) {
        // Mem.create needs a stable pointer; use page_allocator (not debug GPA).
        ac_mem_backend = AutoCompleteMem.create(std.heap.page_allocator) catch {
            @panic("byakaron: failed to init autocomplete mem backend");
        };
    }
    return ac_mem_backend.?.autoComplete();
}

pub fn checkText(allocator: std.mem.Allocator, text: []const u8) ![]const TokenResult {
    return try (try spellEngine()).checkText(allocator, text);
}

pub fn checkWords(allocator: std.mem.Allocator, words: []const []const u8) ![]const TokenResult {
    return try (try spellEngine()).checkWords(allocator, words);
}

/// Lexicon prefix suggestions via spell.db `dictionary` (Spell engine API).
pub fn prefixSuggest(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Suggestion {
    return try (try spellEngine()).prefixSuggest(allocator, prefix, limit);
}

pub fn nextWordSuggest(allocator: std.mem.Allocator, prev: []const u8, limit: i64) ![]const Suggestion {
    return try (try spellEngine()).nextWordSuggest(allocator, prev, limit);
}

/// Prefix autocomplete ranked by the AutoComplete engine over spell.db.
pub fn autoCompletePrefix(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const AutoCompleteSuggestion {
    return try autoCompleteSqlite().prefixSuggest(allocator, prefix, limit);
}

/// In-memory Avro dictionary autocomplete (no DB round-trip).
pub fn autoCompleteMemPrefix(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const AutoCompleteSuggestion {
    return try autoCompleteMem().prefixSuggest(allocator, prefix, limit);
}
