//! C-ABI FFI surface for libbyakaron.
//!
//! These exports let non-Zig callers (the macOS Swift app/IME, etc.) drive the
//! transliteration engine across the C boundary. The header counterpart lives in
//! `src/ffi/byakaron.h`.
//!
//! Memory: returned strings are heap-allocated with the C allocator and are
//! NUL-terminated. The caller owns them and must release each one with
//! `byakaron_string_free`. Returning `null` signals allocation/transliteration
//! failure.
const std = @import("std");
const Transliteration = @import("transliteration");
const Mode = Transliteration.Mode;

/// Transliteration mode selector for the C ABI. Mirrors `Mode` but as a stable
/// integer so the value is meaningful from C/Swift.
pub const BYAKARON_MODE_AVRO: c_int = 0;
pub const BYAKARON_MODE_ORVA: c_int = 1;

/// Transliterate a NUL-terminated UTF-8 string.
///
/// `mode` is one of the `BYAKARON_MODE_*` values. Returns a freshly allocated,
/// NUL-terminated UTF-8 string the caller must free with `byakaron_string_free`,
/// or `null` on failure (unknown mode or out of memory).
pub export fn byakaron_transliterate(mode: c_int, text: [*:0]const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const input = std.mem.span(text);

    const result: []u8 = switch (mode) {
        BYAKARON_MODE_AVRO => run(allocator, .avro, input),
        BYAKARON_MODE_ORVA => run(allocator, .orva, input),
        else => return null,
    } orelse return null;
    defer allocator.free(result);

    // Copy into a NUL-terminated buffer the caller can treat as a C string.
    const out = allocator.allocSentinel(u8, result.len, 0) catch return null;
    @memcpy(out, result);
    return out.ptr;
}

/// Free a string previously returned by `byakaron_transliterate`.
pub export fn byakaron_string_free(ptr: ?[*:0]u8) void {
    if (ptr) |p| {
        std.heap.c_allocator.free(std.mem.span(p));
    }
}

// ── Persistent engine handle ────────────────────────────────────────────────
//
// `byakaron_transliterate` above rebuilds the matching trie on every call, which
// is convenient but wasteful for repeated use (e.g. an input method running on
// every keystroke). The handle API below builds the engine ONCE and reuses it.
//
// `Transliteration.init` takes a comptime mode, so the handle stores a tagged
// instance per mode and dispatches on the tag.

pub const Engine = struct {
    inner: union(enum) {
        avro: Transliteration,
        orva: Transliteration,
    },

    fn transliterate(self: *Engine, input: []const u8) []u8 {
        return switch (self.inner) {
            .avro => |*t| t.transliterate(input),
            .orva => |*t| t.transliterate(input),
        };
    }

    fn deinit(self: *Engine) void {
        switch (self.inner) {
            .avro => |*t| t.deinit(),
            .orva => |*t| t.deinit(),
        }
    }
};

/// Create a reusable transliteration engine for `mode`. Returns an opaque handle
/// the caller must release with `byakaron_engine_destroy`, or `null` on failure.
pub export fn byakaron_engine_create(mode: c_int) ?*Engine {
    const allocator = std.heap.c_allocator;
    const engine = allocator.create(Engine) catch return null;
    engine.* = switch (mode) {
        BYAKARON_MODE_AVRO => .{ .inner = .{ .avro = Transliteration.init(allocator, .avro) } },
        BYAKARON_MODE_ORVA => .{ .inner = .{ .orva = Transliteration.init(allocator, .orva) } },
        else => {
            allocator.destroy(engine);
            return null;
        },
    };
    return engine;
}

/// Transliterate using a pre-built engine. Returns a freshly allocated,
/// NUL-terminated string (free with `byakaron_string_free`), or `null`.
pub export fn byakaron_engine_transliterate(engine: ?*Engine, text: [*:0]const u8) ?[*:0]u8 {
    const e = engine orelse return null;
    const allocator = std.heap.c_allocator;
    const result = e.transliterate(std.mem.span(text));
    defer allocator.free(result);

    const out = allocator.allocSentinel(u8, result.len, 0) catch return null;
    @memcpy(out, result);
    return out.ptr;
}

/// Destroy an engine created with `byakaron_engine_create`.
pub export fn byakaron_engine_destroy(engine: ?*Engine) void {
    if (engine) |e| {
        e.deinit();
        std.heap.c_allocator.destroy(e);
    }
}

/// Run a single transliteration for the given (comptime) mode, returning an
/// owned slice or `null` on failure. `Transliteration.init` takes a comptime
/// mode, so the public modes are dispatched by the caller above.
fn run(allocator: std.mem.Allocator, comptime mode: Mode, input: []const u8) ?[]u8 {
    var t = Transliteration.init(allocator, mode);
    defer t.deinit();
    // `transliterate` allocates with the same allocator; caller frees.
    return t.transliterate(input);
}

// ── Spell engine (SQLite via zx.Db.Sqlite) ───────────────────────────────────

const Spell = @import("spell");
const SpellSqlite = @import("../Spell/Sqlite.zig");
const Tokenizer = @import("tokenization").Tokenizer;

var spell_io_backend: std.Io.Threaded = .init_single_threaded;

pub const SpellHandle = struct {
    backend: *SpellSqlite,
};

/// Open a Byakaron.db and return an opaque handle, or null on failure.
pub export fn byakaron_spell_create(db_path: [*:0]const u8) ?*SpellHandle {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(db_path);
    const backend = SpellSqlite.init(allocator, spell_io_backend.io(), path) catch return null;
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

/// Tokenize Bangla `text` into words (nukta-normalized). Returns a JSON string
/// array (free with byakaron_string_free), or NULL on failure. No handle needed.
pub export fn byakaron_tokenize_words(text: [*:0]const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const words = Tokenizer.wordsFromText(a, std.mem.span(text), .{ .normalize = true }) catch return null;
    const json = stringifyStrings(a, words) catch return null;
    return dupeCString(allocator, json);
}

/// List variant of `byakaron_tokenize_words`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`). Returns the count written. `text` must be NUL-terminated.
pub export fn byakaron_tokenize_list(
    text: [*:0]const u8,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const words = Tokenizer.wordsFromText(a, std.mem.span(text), .{ .normalize = true }) catch return 0;

    var count: usize = 0;
    for (words) |w| {
        if (count >= max_out) break;
        if (w.len == 0) continue;
        if (dupeCString(allocator, w)) |cstr| {
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

fn dupeCString(allocator: std.mem.Allocator, s: []const u8) ?[*:0]u8 {
    const out = allocator.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(out, s);
    return out.ptr;
}

fn stringifyCheckResults(allocator: std.mem.Allocator, results: []const Spell.TokenResult) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(allocator, '[');
    for (results, 0..) |r, i| {
        if (i > 0) try list.append(allocator, ',');
        try list.appendSlice(allocator, "{\"token\":");
        try appendJsonString(allocator, &list, r.token);
        try list.appendSlice(allocator, ",\"known\":");
        try list.appendSlice(allocator, if (r.known) "true" else "false");
        try list.appendSlice(allocator, ",\"suggestions\":[");
        for (r.suggestions, 0..) |s, j| {
            if (j > 0) try list.append(allocator, ',');
            try list.appendSlice(allocator, "{\"word\":");
            try appendJsonString(allocator, &list, s.word);
            var buf: [128]u8 = undefined;
            const meta = try std.fmt.bufPrint(&buf, ",\"frequency\":{d},\"distance\":{d},\"score\":{d}}}", .{ s.frequency, s.distance, s.score });
            try list.appendSlice(allocator, meta);
        }
        try list.appendSlice(allocator, "]}");
    }
    try list.append(allocator, ']');
    return try list.toOwnedSlice(allocator);
}

fn stringifySuggestionWords(allocator: std.mem.Allocator, suggestions: []const Spell.Suggestion) ![]u8 {
    return stringifyWords(allocator, suggestions);
}

fn stringifyWords(allocator: std.mem.Allocator, suggestions: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(allocator, '[');
    for (suggestions, 0..) |s, i| {
        if (i > 0) try list.append(allocator, ',');
        try appendJsonString(allocator, &list, s.word);
    }
    try list.append(allocator, ']');
    return try list.toOwnedSlice(allocator);
}

fn stringifyStrings(allocator: std.mem.Allocator, words: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    try list.append(allocator, '[');
    for (words, 0..) |w, i| {
        if (i > 0) try list.append(allocator, ',');
        try appendJsonString(allocator, &list, w);
    }
    try list.append(allocator, ']');
    return try list.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
}

// ── Autocomplete (in-memory lexicon from the Avro dictionary) ───────────────

const AutoCompleteMem = @import("autocomplete_mem");

pub const AutoCompleteHandle = struct {
    backend: *AutoCompleteMem,
};

/// Create the embedded Mem autocomplete engine (no DB path required).
pub export fn byakaron_ac_create() ?*AutoCompleteHandle {
    const allocator = std.heap.c_allocator;
    const backend = AutoCompleteMem.create(allocator) catch return null;
    const handle = allocator.create(AutoCompleteHandle) catch {
        backend.destroy(allocator);
        return null;
    };
    handle.* = .{ .backend = backend };
    return handle;
}

pub export fn byakaron_ac_destroy(ac: ?*AutoCompleteHandle) void {
    const handle = ac orelse return;
    const allocator = std.heap.c_allocator;
    handle.backend.destroy(allocator);
    allocator.destroy(handle);
}

/// Prefix completions for a Bangla `prefix`. Returns a JSON string array
/// (free with byakaron_string_free), or NULL on failure.
pub export fn byakaron_ac_prefix(ac: ?*AutoCompleteHandle, prefix: [*:0]const u8, limit: c_int) ?[*:0]u8 {
    const handle = ac orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) limit else 24;
    const suggestions = handle.backend.autoComplete().prefixSuggest(a, std.mem.span(prefix), lim) catch return null;
    const json = stringifyWords(a, suggestions) catch return null;
    return dupeCString(allocator, json);
}

/// 1 if `word` is in the lexicon, 0 otherwise, -1 on error.
pub export fn byakaron_ac_contains(ac: ?*AutoCompleteHandle, word: [*:0]const u8) c_int {
    const handle = ac orelse return -1;
    return if (handle.backend.autoComplete().contains(std.mem.span(word))) 1 else 0;
}

/// List variant of `byakaron_ac_prefix`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`). Returns the count written.
pub export fn byakaron_ac_prefix_list(
    ac: ?*AutoCompleteHandle,
    prefix: [*:0]const u8,
    limit: c_int,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
) usize {
    const handle = ac orelse return 0;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lim: i64 = if (limit > 0) @min(@as(i64, @intCast(limit)), @as(i64, @intCast(max_out))) else @min(24, @as(i64, @intCast(max_out)));
    const suggestions = handle.backend.autoComplete().prefixSuggest(a, std.mem.span(prefix), lim) catch return 0;

    var count: usize = 0;
    for (suggestions) |s| {
        if (count >= max_out) break;
        if (dupeCString(allocator, s.word)) |cstr| {
            out_ptrs[count] = cstr;
            count += 1;
        }
    }
    return count;
}

// ── Avro suggestions (iAvro's candidate list from the Latin buffer) ─────────

/// Avro candidates for the composed Latin `latin` (see `AutoComplete.suggest`).
/// Returns JSON `{"candidates":["…"],"selected":N}`, N being the candidate to
/// highlight (free with byakaron_string_free), or NULL on failure.
pub export fn byakaron_ac_suggest(ac: ?*AutoCompleteHandle, latin: [*:0]const u8) ?[*:0]u8 {
    const handle = ac orelse return null;
    const allocator = std.heap.c_allocator;
    var c = handle.backend.autoComplete().suggest(allocator, std.mem.span(latin)) catch return null;
    defer c.deinit();
    const json = std.json.Stringify.valueAlloc(allocator, .{ .candidates = c.items, .selected = c.selected }, .{}) catch return null;
    defer allocator.free(json);
    return dupeCString(allocator, json);
}

/// List variant of `byakaron_ac_suggest`. Fills `out_ptrs` (free each with
/// `byakaron_string_free`), sets `*selected` (if non-NULL) to the index to
/// highlight, and returns the count written.
pub export fn byakaron_ac_suggest_list(
    ac: ?*AutoCompleteHandle,
    latin: [*:0]const u8,
    out_ptrs: [*][*:0]u8,
    max_out: usize,
    selected: ?*c_int,
) usize {
    const handle = ac orelse return 0;
    const allocator = std.heap.c_allocator;
    var c = handle.backend.autoComplete().suggest(allocator, std.mem.span(latin)) catch return 0;
    defer c.deinit();
    var count: usize = 0;
    for (c.items) |item| {
        if (count >= max_out) break;
        out_ptrs[count] = dupeCString(allocator, item) orelse break;
        count += 1;
    }
    if (selected) |s| s.* = if (c.selected < count) @intCast(c.selected) else 0;
    return count;
}

/// Remember `candidate` (as shown) as the user's choice for `latin`, so the next
/// `byakaron_ac_suggest` highlights it. Call it when the highlighted candidate
/// changes, as iAvro does. Returns 0, or -1 on failure.
pub export fn byakaron_ac_select(ac: ?*AutoCompleteHandle, latin: [*:0]const u8, candidate: [*:0]const u8) c_int {
    const handle = ac orelse return -1;
    handle.backend.autoComplete().select(std.heap.c_allocator, std.mem.span(latin), std.mem.span(candidate)) catch return -1;
    return 0;
}

/// The learned choices as a JSON object (`{"<latin>":"<Bangla>"}`) to persist
/// (free with byakaron_string_free), or NULL on failure.
pub export fn byakaron_ac_export_selections(ac: ?*AutoCompleteHandle) ?[*:0]u8 {
    const handle = ac orelse return null;
    const allocator = std.heap.c_allocator;
    const json = handle.backend.autoComplete().exportSelections(allocator) catch return null;
    defer allocator.free(json);
    return dupeCString(allocator, json);
}

/// Merge choices saved with `byakaron_ac_export_selections`. Returns 0, or -1
/// on failure (invalid JSON).
pub export fn byakaron_ac_import_selections(ac: ?*AutoCompleteHandle, json: [*:0]const u8) c_int {
    const handle = ac orelse return -1;
    handle.backend.autoComplete().importSelections(std.heap.c_allocator, std.mem.span(json)) catch return -1;
    return 0;
}

// ── Composer: the whole keyboard behind one handle ──────────────────────────
//
// Every native keyboard drives this: it maps OS key events to
// `byakaron_composer_key`, applies the result (insert `commit`, consume the key
// or not) and draws `byakaron_composer_state`. See src/Composer.zig.

const Composer = @import("composer");
const SpellCorrector = @import("SpellCorrector.zig");

pub const ComposerHandle = struct {
    composer: Composer,
    files: Composer.FileStore,
    spell: ?*SpellSqlite = null,
    corrector: ?*SpellCorrector = null,
    /// C strings handed out by the last call (state, commit, …).
    out: std.heap.ArenaAllocator,
    out_ptrs: std.ArrayList([*:0]const u8) = .empty,
};

pub const ByakaronKeyResult = extern struct {
    handled: c_int,
    /// NUL-terminated, valid until the next call on the composer.
    commit: [*:0]const u8,
};

pub const ByakaronComposerState = extern struct {
    composing: c_int,
    preedit: [*:0]const u8,
    panel_visible: c_int,
    vertical: c_int,
    candidates: [*]const [*:0]const u8,
    candidate_count: usize,
    highlight: usize,
    page: usize,
    page_count: usize,
};

pub const BYAKARON_MOD_SHIFT: c_uint = 1;
pub const BYAKARON_MOD_CTRL: c_uint = 2;
pub const BYAKARON_MOD_ALT: c_uint = 4;
pub const BYAKARON_MOD_META: c_uint = 8;

const UpdateFn = *const fn (?*anyopaque) callconv(.c) void;

fn noUpdate(_: ?*anyopaque) callconv(.c) void {}

/// Create a composer keeping its settings and learned data in `data_dir`. With
/// `spell_db`, spelling corrections come from it on a worker thread, and
/// `on_update(userdata)` is called — from that thread — when they arrive; call
/// `byakaron_composer_refresh` on the composer's own thread then. Returns NULL
/// on failure.
pub export fn byakaron_composer_create(
    data_dir: [*:0]const u8,
    spell_db: ?[*:0]const u8,
    on_update: ?UpdateFn,
    userdata: ?*anyopaque,
) ?*ComposerHandle {
    const allocator = std.heap.c_allocator;
    const h = allocator.create(ComposerHandle) catch return null;
    h.* = .{ .composer = undefined, .files = undefined, .out = .init(allocator) };
    h.files = Composer.FileStore.init(allocator, spell_io_backend.io(), std.mem.span(data_dir)) catch {
        allocator.destroy(h);
        return null;
    };
    var corrector: ?Composer.Corrector = null;
    if (spell_db) |path| if (SpellSqlite.init(allocator, spell_io_backend.io(), std.mem.span(path))) |backend| {
        h.spell = backend;
        if (SpellCorrector.create(allocator, spell_io_backend.io(), backend.engine(), on_update orelse noUpdate, userdata)) |c| {
            h.corrector = c;
            corrector = c.corrector();
        } else |_| {}
    } else |_| {};
    h.composer = Composer.init(allocator, h.files.store(), corrector) catch {
        destroyParts(h);
        return null;
    };
    return h;
}

fn destroyParts(h: *ComposerHandle) void {
    if (h.corrector) |c| c.destroy();
    if (h.spell) |s| s.deinit();
    h.files.deinit();
    h.out_ptrs.deinit(std.heap.c_allocator);
    h.out.deinit();
    std.heap.c_allocator.destroy(h);
}

pub export fn byakaron_composer_destroy(composer: ?*ComposerHandle) void {
    const h = composer orelse return;
    h.composer.deinit();
    destroyParts(h);
}

fn resetOut(h: *ComposerHandle) void {
    _ = h.out.reset(.retain_capacity);
    h.out_ptrs.clearRetainingCapacity();
}

fn outString(h: *ComposerHandle, s: []const u8) [*:0]const u8 {
    return (h.out.allocator().dupeSentinel(u8, s, 0) catch return "").ptr;
}

fn keyResult(h: *ComposerHandle, outcome: anyerror!Composer.Outcome) ByakaronKeyResult {
    const o = outcome catch return .{ .handled = 0, .commit = "" };
    return .{ .handled = @intFromBool(o.handled), .commit = outString(h, o.commit) };
}

/// One key. `kind` is a BYAKARON_KEY_* value, `ch` the ASCII character for
/// BYAKARON_KEY_CHAR, `modifiers` BYAKARON_MOD_* bits.
pub export fn byakaron_composer_key(composer: ?*ComposerHandle, kind: c_int, ch: c_uint, modifiers: c_uint) ByakaronKeyResult {
    const h = composer orelse return .{ .handled = 0, .commit = "" };
    resetOut(h);
    const k: Composer.Key = switch (kind) {
        0 => if (ch >= 0x21 and ch <= 0x7e) .{ .char = @intCast(ch) } else .other,
        1 => .space,
        2 => .enter,
        3 => .tab,
        4 => .backspace,
        5 => .escape,
        6 => .up,
        7 => .down,
        8 => .left,
        9 => .right,
        10 => .page_up,
        11 => .page_down,
        else => .other,
    };
    const mods: Composer.Modifiers = .{
        .shift = modifiers & BYAKARON_MOD_SHIFT != 0,
        .ctrl = modifiers & BYAKARON_MOD_CTRL != 0,
        .alt = modifiers & BYAKARON_MOD_ALT != 0,
        .meta = modifiers & BYAKARON_MOD_META != 0,
    };
    return keyResult(h, h.composer.key(k, mods));
}

/// Choose the `index`th candidate of the current page (a click) and commit it.
pub export fn byakaron_composer_pick(composer: ?*ComposerHandle, index: usize) ByakaronKeyResult {
    const h = composer orelse return .{ .handled = 0, .commit = "" };
    resetOut(h);
    return keyResult(h, h.composer.pick(index));
}

/// Commit the word being typed (focus leaving). Returns the text to insert
/// ("" if none), valid until the next call.
pub export fn byakaron_composer_flush(composer: ?*ComposerHandle) [*:0]const u8 {
    const h = composer orelse return "";
    resetOut(h);
    const text = h.composer.flush() catch return "";
    return outString(h, text);
}

/// Drop the word being typed without committing it.
pub export fn byakaron_composer_reset(composer: ?*ComposerHandle) void {
    const h = composer orelse return;
    h.composer.reset();
}

/// Rebuild the candidates (after `on_update`), on the composer's thread.
pub export fn byakaron_composer_refresh(composer: ?*ComposerHandle) void {
    const h = composer orelse return;
    h.composer.refresh() catch {};
}

/// What to draw. Pointers stay valid until the next call on the composer.
pub export fn byakaron_composer_state(composer: ?*ComposerHandle, out: ?*ByakaronComposerState) void {
    const h = composer orelse return;
    const o = out orelse return;
    resetOut(h);
    const c = &h.composer;
    for (c.pageItems()) |item| h.out_ptrs.append(std.heap.c_allocator, outString(h, item)) catch break;
    o.* = .{
        .composing = @intFromBool(c.composing()),
        .preedit = outString(h, c.preedit()),
        .panel_visible = @intFromBool(c.panelVisible()),
        .vertical = @intFromBool(c.settings.candidate_orientation == .vertical),
        .candidates = h.out_ptrs.items.ptr,
        .candidate_count = h.out_ptrs.items.len,
        .highlight = c.pageHighlight(),
        .page = c.page(),
        .page_count = c.pageCount(),
    };
}

/// The settings as JSON (see src/Composer/Settings.zig); free with
/// byakaron_string_free.
pub export fn byakaron_settings_get(composer: ?*ComposerHandle) ?[*:0]u8 {
    const h = composer orelse return null;
    h.composer.sync();
    const json = h.composer.settings.stringify(std.heap.c_allocator) catch return null;
    defer std.heap.c_allocator.free(json);
    return dupeCString(std.heap.c_allocator, json);
}

/// Apply and save settings JSON (missing fields keep their defaults). Returns
/// 0, or -1 if the JSON is invalid.
pub export fn byakaron_settings_set(composer: ?*ComposerHandle, json: [*:0]const u8) c_int {
    const h = composer orelse return -1;
    const s = Composer.Settings.parse(std.heap.c_allocator, std.mem.span(json)) catch return -1;
    h.composer.setSettings(s) catch return -1;
    return 0;
}

/// The personal dictionary as a JSON array of words; free with
/// byakaron_string_free.
pub export fn byakaron_userdict_get(composer: ?*ComposerHandle) ?[*:0]u8 {
    const h = composer orelse return null;
    h.composer.sync();
    const json = std.json.Stringify.valueAlloc(std.heap.c_allocator, h.composer.user_words.words.items, .{}) catch return null;
    defer std.heap.c_allocator.free(json);
    return dupeCString(std.heap.c_allocator, json);
}

/// Add a word to the personal dictionary. 1 if added, 0 if already there or
/// not a word, -1 on error.
pub export fn byakaron_userdict_add(composer: ?*ComposerHandle, word: [*:0]const u8) c_int {
    const h = composer orelse return -1;
    h.composer.sync();
    return if (h.composer.addUserWord(std.mem.span(word))) |added| @intFromBool(added) else |_| -1;
}

/// Remove a word. 1 if removed, 0 if absent, -1 on error.
pub export fn byakaron_userdict_remove(composer: ?*ComposerHandle, word: [*:0]const u8) c_int {
    const h = composer orelse return -1;
    h.composer.sync();
    return if (h.composer.removeUserWord(std.mem.span(word))) |removed| @intFromBool(removed) else |_| -1;
}

// ------------ TESTING ------------

test "composer ABI: type, draw, commit, settings, personal words" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const c = byakaron_composer_create(dir.ptr, null, null, null) orelse return error.CreateFailed;
    defer byakaron_composer_destroy(c);

    for ("bhalo") |ch| try testing.expectEqual(@as(c_int, 1), byakaron_composer_key(c, 0, ch, 0).handled);
    var st: ByakaronComposerState = undefined;
    byakaron_composer_state(c, &st);
    try testing.expectEqual(@as(c_int, 1), st.composing);
    try testing.expectEqual(@as(c_int, 1), st.panel_visible);
    try testing.expectEqualStrings("ভাল", std.mem.span(st.preedit));
    try testing.expect(st.candidate_count > 1);
    try testing.expectEqualStrings("ভাল", std.mem.span(st.candidates[0]));

    const r = byakaron_composer_key(c, 1, 0, 0); // space
    try testing.expectEqual(@as(c_int, 1), r.handled);
    try testing.expectEqualStrings("ভাল ", std.mem.span(r.commit));

    try testing.expectEqual(@as(c_int, 0), byakaron_settings_set(c, "{\"suggestions\":false}"));
    const json = byakaron_settings_get(c).?;
    defer byakaron_string_free(json);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(json), "\"suggestions\": false") != null);
    try testing.expectEqual(@as(c_int, -1), byakaron_settings_set(c, "{"));

    try testing.expectEqual(@as(c_int, 1), byakaron_userdict_add(c, "বাংলাভাষী"));
    try testing.expectEqual(@as(c_int, 0), byakaron_userdict_add(c, "বাংলাভাষী"));
    const words = byakaron_userdict_get(c).?;
    defer byakaron_string_free(words);
    try testing.expectEqualStrings("[\"বাংলাভাষী\"]", std.mem.span(words));
    try testing.expectEqual(@as(c_int, 1), byakaron_userdict_remove(c, "বাংলাভাষী"));

    // A second composer on the same directory sees the saved settings.
    const d = byakaron_composer_create(dir.ptr, null, null, null) orelse return error.CreateFailed;
    defer byakaron_composer_destroy(d);
    for ("bhalo") |ch| _ = byakaron_composer_key(d, 0, ch, 0);
    byakaron_composer_state(d, &st);
    try testing.expectEqual(@as(c_int, 0), st.panel_visible);
}
