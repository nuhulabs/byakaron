//! Thin webz façade over byakaron `src/` spell + autocomplete backends.
//!
//! Storage is the ziex app database (`zx.db` ← installed `spell.db`).
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

var spell_backend: SpellSqlite = undefined;
var spell_ready: bool = false;

var ac_sqlite_backend: AutoCompleteSqlite = undefined;
var ac_sqlite_ready: bool = false;

var ac_mem_backend: ?*AutoCompleteMem = null;

fn spellEngine() *Spell {
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

/// In-memory macos dictionary autocomplete (no DB round-trip).
pub fn autoCompleteMemPrefix(allocator: std.mem.Allocator, prefix: []const u8, limit: i64) ![]const AutoCompleteSuggestion {
    return try autoCompleteMem().prefixSuggest(allocator, prefix, limit);
}
