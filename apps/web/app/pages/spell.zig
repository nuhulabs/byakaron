//! Thin web façade over byakaron `src/` spell + autocomplete backends.
//!
//! Storage is `<install prefix>/db/spell.db` (built by `zig build db`), opened
//! read-only. `zx dev` / `zx serve` set ZIEX_ROOT_DIR to the install prefix.
//! Backends are process-static (no heap) so hot-reload doesn't trip leak checks.

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

var db: zx.Db = undefined;
var db_ready: bool = false;

var spell_backend: SpellSqlite = undefined;
var spell_ready: bool = false;

var ac_sqlite_backend: AutoCompleteSqlite = undefined;
var ac_sqlite_ready: bool = false;

var ac_mem_backend: ?*AutoCompleteMem = null;

fn spellDb() *zx.Db {
    if (!db_ready) {
        const allocator = std.heap.page_allocator;
        const root: []const u8 = if (std.c.getenv("ZIEX_ROOT_DIR")) |r| std.mem.span(r) else "zig-out";
        const path = std.fs.path.join(allocator, &.{ root, "db", "spell.db" }) catch @panic("OOM");
        db = zx.Db.Sqlite.open(allocator, zx.io(), path, .{
            .readonly = true,
            .create = false,
            .readwrite = false,
            // ziex's pooled mode forces `journal_mode=wal`, which a read-only
            // connection rejects; one serialized connection is plenty here.
            .max_pool_size = 1,
        }) catch |err| std.debug.panic("byakaron: cannot open {s} ({t}); run `zig build db`", .{ path, err });
        db_ready = true;
    }
    return &db;
}

fn spellEngine() *Spell {
    if (!spell_ready) {
        SpellSqlite.initBorrowedInto(&spell_backend, spellDb());
        spell_ready = true;
    }
    return spell_backend.engine();
}

fn autoCompleteSqlite() *AutoComplete {
    if (!ac_sqlite_ready) {
        AutoCompleteSqlite.initBorrowedInto(&ac_sqlite_backend, spellDb());
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
    return try spellEngine().checkText(allocator, text);
}

/// Lexicon prefix suggestions via spell.db `dictionary` (Spell engine API).
pub fn prefixSuggest(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const Suggestion {
    return try spellEngine().prefixSuggest(allocator, prefix, limit);
}

pub fn nextWordSuggest(allocator: std.mem.Allocator, prev: []const u8, limit: i64) ![]const Suggestion {
    return try spellEngine().nextWordSuggest(allocator, prev, limit);
}

/// Prefix autocomplete ranked by the AutoComplete engine over spell.db.
pub fn autoCompletePrefix(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const AutoCompleteSuggestion {
    return try autoCompleteSqlite().prefixSuggest(allocator, prefix, limit);
}

/// In-memory Avro dictionary autocomplete (no DB round-trip).
pub fn autoCompleteMemPrefix(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const AutoCompleteSuggestion {
    return try autoCompleteMem().prefixSuggest(allocator, prefix, limit);
}
