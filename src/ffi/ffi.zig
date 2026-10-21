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
const Transliteration = @import("../transliteration/transliteration.zig").Transliteration;
const Mode = @import("../transliteration/transliteration.zig").Mode;

/// Transliteration mode selector for the C ABI. Mirrors `Mode` but as a stable
/// integer so the value is meaningful from C/Swift.
pub const BYAKARON_MODE_AVRO: c_int = 0;
pub const BYAKARON_MODE_ORVA: c_int = 1;

/// Transliterate a NUL-terminated UTF-8 string.
///
/// `mode` is one of the `BYAKARON_MODE_*` values. Returns a freshly allocated,
/// NUL-terminated UTF-8 string the caller must free with `byakaron_string_free`,
/// or `null` on failure (unknown mode or out of memory).
export fn byakaron_transliterate(mode: c_int, text: [*:0]const u8) ?[*:0]u8 {
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
export fn byakaron_string_free(ptr: ?[*:0]u8) void {
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

const Engine = struct {
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
export fn byakaron_engine_create(mode: c_int) ?*Engine {
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
export fn byakaron_engine_transliterate(engine: ?*Engine, text: [*:0]const u8) ?[*:0]u8 {
    const e = engine orelse return null;
    const allocator = std.heap.c_allocator;
    const result = e.transliterate(std.mem.span(text));
    defer allocator.free(result);

    const out = allocator.allocSentinel(u8, result.len, 0) catch return null;
    @memcpy(out, result);
    return out.ptr;
}

/// Destroy an engine created with `byakaron_engine_create`.
export fn byakaron_engine_destroy(engine: ?*Engine) void {
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

var spell_io_backend: std.Io.Threaded = .init_single_threaded;

const SpellHandle = struct {
    backend: *SpellSqlite,
};

/// Open a spell.db and return an opaque handle, or null on failure.
export fn byakaron_spell_create(db_path: [*:0]const u8) ?*SpellHandle {
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

export fn byakaron_spell_destroy(spell: ?*SpellHandle) void {
    const handle = spell orelse return;
    handle.backend.deinit();
    std.heap.c_allocator.destroy(handle);
}

export fn byakaron_spell_check(spell: ?*SpellHandle, text: [*:0]const u8) ?[*:0]u8 {
    const handle = spell orelse return null;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const results = handle.backend.engine().checkText(a, std.mem.span(text)) catch return null;
    const json = stringifyCheckResults(a, results) catch return null;
    return dupeCString(allocator, json);
}

export fn byakaron_spell_suggest(spell: ?*SpellHandle, word: [*:0]const u8, limit: c_int) ?[*:0]u8 {
    return byakaron_spell_suggest_ctx(spell, word, "", "", "", limit);
}

export fn byakaron_spell_suggest_ctx(
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

export fn byakaron_spell_is_correct(spell: ?*SpellHandle, word: [*:0]const u8) c_int {
    const handle = spell orelse return -1;
    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = std.mem.span(word);
    if (w.len == 0) return 1;

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

const AutoCompleteHandle = struct {
    backend: *AutoCompleteMem,
};

/// Create the embedded Mem autocomplete engine (no DB path required).
export fn byakaron_ac_create() ?*AutoCompleteHandle {
    const allocator = std.heap.c_allocator;
    const backend = AutoCompleteMem.create(allocator) catch return null;
    const handle = allocator.create(AutoCompleteHandle) catch {
        backend.destroy(allocator);
        return null;
    };
    handle.* = .{ .backend = backend };
    return handle;
}

export fn byakaron_ac_destroy(ac: ?*AutoCompleteHandle) void {
    const handle = ac orelse return;
    const allocator = std.heap.c_allocator;
    handle.backend.destroy(allocator);
    allocator.destroy(handle);
}

/// Prefix completions for a Bangla `prefix`. Returns a JSON string array
/// (free with byakaron_string_free), or NULL on failure.
export fn byakaron_ac_prefix(ac: ?*AutoCompleteHandle, prefix: [*:0]const u8, limit: c_int) ?[*:0]u8 {
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
export fn byakaron_ac_contains(ac: ?*AutoCompleteHandle, word: [*:0]const u8) c_int {
    const handle = ac orelse return -1;
    return if (handle.backend.autoComplete().contains(std.mem.span(word))) 1 else 0;
}
