//! The spell engine's C ABI (SQLite through zx.Db.Sqlite): `byakaron_spell_*`.
//! Part of libbyakaron except on iOS, whose keyboard uses only the composer
//! and the in-memory lexicon (see ffi.zig).

const std = @import("std");
const ffi = @import("ffi.zig");
const Composer = @import("composer");
const dupeCString = ffi.dupeCString;
const stringifyCheckResults = ffi.stringifyCheckResults;
const stringifySuggestionWords = ffi.stringifySuggestionWords;
const stringifyWords = ffi.stringifyWords;
const Spell = @import("spell");
const SpellSqlite = @import("../Spell/Sqlite.zig");

/// The Io for SQLite and the composer's files. Not on iOS (see ffi.zig).
pub var io_backend: std.Io.Threaded = .init_single_threaded;

pub const SpellHandle = struct {
    backend: *SpellSqlite,
};

/// Open a Byakaron.db and return an opaque handle, or null on failure.
pub export fn byakaron_spell_create(db_path: [*:0]const u8) ?*SpellHandle {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(db_path);
    const backend = SpellSqlite.init(allocator, io_backend.io(), path) catch return null;
    const handle = allocator.create(SpellHandle) catch {
        backend.deinit();
        return null;
    };
    handle.* = .{ .backend = backend };
    return handle;
}

pub export fn byakaron_spell_destroy(spell: ?*SpellHandle) void {
    const handle = spell orelse return;
    handle.backend.deinit();
    std.heap.c_allocator.destroy(handle);
}

pub export fn byakaron_spell_check(spell: ?*SpellHandle, text: [*:0]const u8) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const results = handle.backend.engine().checkText(a, std.mem.span(text)) catch return null;
    const json = stringifyCheckResults(a, results) catch return null;
    return dupeCString(allocator, json);
}

pub export fn byakaron_spell_suggest(spell: ?*SpellHandle, word: [*:0]const u8, limit: c_int) ?[*:0]u8 {
    return byakaron_spell_suggest_ctx(spell, word, "", "", "", limit);
}

pub export fn byakaron_spell_suggest_ctx(
    spell: ?*SpellHandle,
    word: [*:0]const u8,
    prev2: [*:0]const u8,
    prev1: [*:0]const u8,
    next: [*:0]const u8,
    limit: c_int,
) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: usize = if (limit > 0) @intCast(limit) else 8;
    const ranked = handle.backend.engine().suggestWord(
        a,
        std.mem.span(word),
        std.mem.span(prev2),
        std.mem.span(prev1),
        std.mem.span(next),
        lim,
    ) catch return null;

    const json = stringifyWords(a, ranked) catch return null;
    return dupeCString(allocator, json);
}

/// Fills `out_ptrs` with up to `max_out` ranked suggestion C-strings.
/// Caller must free each allocated C-string using `byakaron_string_free`.
/// Returns the number of suggestions written.
pub export fn byakaron_spell_suggest_list(
    spell: ?*SpellHandle,
    word: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    return byakaron_spell_suggest_ctx_list(spell, word, "", "", "", limit, out_ptrs, max_out);
}

/// Context-aware list variant: ranks `word` with trigram/bigram neighbors
/// (`prev2 prev1 [word] next`). Pass "" for unused neighbors.
/// Fills `out_ptrs` with up to `max_out` C-strings (free each with
/// `byakaron_string_free`). Returns the count written.
pub export fn byakaron_spell_suggest_ctx_list(
    spell: ?*SpellHandle,
    word: [*:0]const u8,
    prev2: [*:0]const u8,
    prev1: [*:0]const u8,
    next: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const handle = spell orelse return 0;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: usize = if (limit > 0) @min(@as(usize, @intCast(limit)), max_out) else @min(8, max_out);
    const ranked = handle.backend.engine().suggestWord(
        a,
        std.mem.span(word),
        std.mem.span(prev2),
        std.mem.span(prev1),
        std.mem.span(next),
        lim,
    ) catch return 0;

    var count: usize = 0;
    for (ranked) |s| {
        if (count >= max_out) break;
        if (dupeCString(allocator, s.word)) |cstr| {
            out_ptrs[count] = cstr;
            count += 1;
        }
    }
    return count;
}

/// Prefix completions from `Byakaron.db` dictionary. Returns a JSON string array
/// (free with byakaron_string_free), or NULL on failure.
pub export fn byakaron_spell_prefix(spell: ?*SpellHandle, prefix: [*:0]const u8, limit: c_int) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) limit else 8;
    const ranked = handle.backend.engine().prefixSuggest(a, std.mem.span(prefix), lim) catch return null;
    const json = stringifyWords(a, ranked) catch return null;
    return dupeCString(allocator, json);
}

/// List variant of `byakaron_spell_prefix`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`). Returns the count written.
pub export fn byakaron_spell_prefix_list(
    spell: ?*SpellHandle,
    prefix: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const handle = spell orelse return 0;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) @min(@as(i64, @intCast(limit)), @as(i64, @intCast(max_out))) else @min(8, @as(i64, @intCast(max_out)));
    const ranked = handle.backend.engine().prefixSuggest(a, std.mem.span(prefix), lim) catch return 0;

    var count: usize = 0;
    for (ranked) |s| {
        if (count >= max_out) break;
        if (dupeCString(allocator, s.word)) |cstr| {
            out_ptrs[count] = cstr;
            count += 1;
        }
    }
    return count;
}

/// Next-word predictions from `Byakaron.db` bigrams for `previous_word`.
/// Returns a JSON string array (free with byakaron_string_free), or NULL.
pub export fn byakaron_spell_next_word(spell: ?*SpellHandle, previous_word: [*:0]const u8, limit: c_int) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) limit else 8;
    const ranked = handle.backend.engine().nextWordSuggest(a, std.mem.span(previous_word), lim) catch return null;
    const json = stringifyWords(a, ranked) catch return null;
    return dupeCString(allocator, json);
}

/// List variant of `byakaron_spell_next_word`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`). Returns the count written.
pub export fn byakaron_spell_next_word_list(
    spell: ?*SpellHandle,
    previous_word: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const handle = spell orelse return 0;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) @min(@as(i64, @intCast(limit)), @as(i64, @intCast(max_out))) else @min(8, @as(i64, @intCast(max_out)));
    const ranked = handle.backend.engine().nextWordSuggest(a, std.mem.span(previous_word), lim) catch return 0;

    var count: usize = 0;
    for (ranked) |s| {
        if (count >= max_out) break;
        if (dupeCString(allocator, s.word)) |cstr| {
            out_ptrs[count] = cstr;
            count += 1;
        }
    }
    return count;
}

/// Trigram next-word predictions from Byakaron.db trigrams (w1, w2 -> w3).
/// Returns a JSON string array (free with byakaron_string_free), or NULL.
pub export fn byakaron_spell_trigram_next_word(
    spell: ?*SpellHandle,
    w1: [*:0]const u8,
    w2: [*:0]const u8,
    limit: c_int,
) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) limit else 8;
    const ranked = handle.backend.engine().trigramNextWordSuggest(a, std.mem.span(w1), std.mem.span(w2), lim) catch return null;
    const json = stringifyWords(a, ranked) catch return null;
    return dupeCString(allocator, json);
}

/// List variant of `byakaron_spell_trigram_next_word`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`). Returns the count written.
pub export fn byakaron_spell_trigram_next_word_list(
    spell: ?*SpellHandle,
    w1: [*:0]const u8,
    w2: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const handle = spell orelse return 0;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) @min(@as(i64, @intCast(limit)), @as(i64, @intCast(max_out))) else @min(8, @as(i64, @intCast(max_out)));
    const ranked = handle.backend.engine().trigramNextWordSuggest(a, std.mem.span(w1), std.mem.span(w2), lim) catch return 0;

    var count: usize = 0;
    for (ranked) |s| {
        if (count >= max_out) break;
        if (dupeCString(allocator, s.word)) |cstr| {
            out_ptrs[count] = cstr;
            count += 1;
        }
    }
    return count;
}

pub export fn byakaron_spell_is_correct(spell: ?*SpellHandle, word: [*:0]const u8) c_int {
    const handle = spell orelse return -1;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = std.mem.span(word);
    if (raw.len == 0) return 1;
    // Byakaron.db spells ড় ঢ় য় as single code points; text from elsewhere often
    // has letter + nukta. Compare in that canonical form.
    const w = (Composer.UserWords.normalize(a, raw) catch return -1) orelse return -1;

    const engine = handle.backend.engine();
    const rows = engine.vtable.lookup_words(engine.ctx, a, &.{w}) catch return -1;
    return if (rows.len > 0) 1 else 0;
}
