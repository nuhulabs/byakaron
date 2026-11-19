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
const builtin = @import("builtin");
const Transliteration = @import("transliteration");
const Mode = Transliteration.Mode;
const Spell = @import("spell");
const Tokenizer = @import("tokenization").Tokenizer;

/// SQLite (the spell engine, the composer's spelling corrections) and the
/// std.Io.Threaded it needs, which Zig 0.17 cannot compile for iOS. The iOS
/// keyboard uses the composer with the in-memory lexicon only.
pub const sqlite = builtin.os.tag != .ios;
const spell_ffi = if (sqlite) @import("spell.zig") else struct {};
comptime {
    if (sqlite) _ = spell_ffi;
}
pub const SpellHandle = if (sqlite) spell_ffi.SpellHandle else opaque {};

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

pub fn dupeCString(allocator: std.mem.Allocator, s: []const u8) ?[*:0]u8 {
    const out = allocator.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(out, s);
    return out.ptr;
}

pub fn stringifyCheckResults(allocator: std.mem.Allocator, results: []const Spell.TokenResult) ![]u8 {
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

pub fn stringifySuggestionWords(allocator: std.mem.Allocator, suggestions: []const Spell.Suggestion) ![]u8 {
    return stringifyWords(allocator, suggestions);
}

pub fn stringifyWords(allocator: std.mem.Allocator, suggestions: anytype) ![]u8 {
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
const SpellSqlite = if (sqlite) @import("../Spell/Sqlite.zig") else void;
const SpellCorrector = if (sqlite) @import("SpellCorrector.zig") else void;
const FileStore = if (sqlite) Composer.FileStore else @import("CFileStore.zig");

pub const ComposerHandle = struct {
    composer: Composer,
    files: FileStore,
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
    /// The Latin being composed (what was typed), "" when idle.
    latin: [*:0]const u8,
    /// The word exactly as typed (plain Avro transliteration), "" when idle.
    literal: [*:0]const u8,
};

// ── Next-word predictions (embedded, no database) ─────────────────────────────

const NextWords = struct { word: []const u8, next: []const []const u8 };
/// Byte-sorted by `word`; `zig build gen -- next-words` regenerates it.
const next_words: []const NextWords = @import("next_words.zon");

/// Up to `max_out` words that most often follow `previous` in the Wikipedia
/// corpus, most likely first, into `out` (static strings: do not free).
/// Returns how many. For keyboards without Byakaron.db (iOS).
pub export fn byakaron_next_words(previous: [*:0]const u8, out: [*][*:0]const u8, max_out: usize) usize {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const raw = std.mem.span(previous);
    const word = (Composer.UserWords.normalize(fba.allocator(), raw) catch null) orelse raw;
    const index = std.sort.binarySearch(NextWords, next_words, word, struct {
        fn order(w: []const u8, e: NextWords) std.math.Order {
            return std.mem.order(u8, w, e.word);
        }
    }.order) orelse return 0;
    var n: usize = 0;
    for (next_words[index].next) |next| {
        if (n >= max_out) break;
        out[n] = @ptrCast(next.ptr);
        n += 1;
    }
    return n;
}

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
    const files = if (sqlite)
        FileStore.init(allocator, spell_ffi.io_backend.io(), std.mem.span(data_dir))
    else
        FileStore.init(allocator, std.mem.span(data_dir));
    h.files = files catch {
        allocator.destroy(h);
        return null;
    };
    var corrector: ?Composer.Corrector = null;
    if (sqlite) {
        if (spell_db) |path| if (SpellSqlite.init(allocator, spell_ffi.io_backend.io(), std.mem.span(path))) |backend| {
            h.spell = backend;
            if (SpellCorrector.create(allocator, spell_ffi.io_backend.io(), backend.engine(), on_update orelse noUpdate, userdata)) |c| {
                h.corrector = c;
                corrector = c.corrector();
            } else |_| {}
        } else |_| {};
    } else {
        _ = .{ spell_db, on_update, userdata };
    }
    h.composer = Composer.init(allocator, h.files.store(), corrector) catch {
        destroyParts(h);
        return null;
    };
    return h;
}

fn destroyParts(h: *ComposerHandle) void {
    if (sqlite) {
        if (h.corrector) |c| c.destroy();
        if (h.spell) |s| s.deinit();
    }
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

/// Choose `word` directly (from the candidate list or an external strip) and
/// commit it, learning the selection when enabled.
pub export fn byakaron_composer_pick_word(composer: ?*ComposerHandle, word: ?[*:0]const u8) ByakaronKeyResult {
    const h = composer orelse return .{ .handled = 0, .commit = "" };
    const w = word orelse return .{ .handled = 0, .commit = "" };
    resetOut(h);
    return keyResult(h, h.composer.pickWord(std.mem.span(w)));
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
        .latin = outString(h, c.latin.items),
        .literal = outString(h, c.literal),
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

/// One setting as a number (see Settings.value). 0, or -1 for an unknown key.
pub export fn byakaron_setting_get(composer: ?*ComposerHandle, key: [*:0]const u8, value: ?*c_int) c_int {
    const h = composer orelse return -1;
    const out = value orelse return -1;
    h.composer.sync();
    out.* = h.composer.settings.value(std.mem.span(key)) orelse return -1;
    return 0;
}

/// Set and save one setting from a number (see Settings.setValue). 0, or -1
/// for an unknown key or a failed save.
pub export fn byakaron_setting_set(composer: ?*ComposerHandle, key: [*:0]const u8, value: c_int) c_int {
    const h = composer orelse return -1;
    // Read-modify-write: another process may have saved since.
    h.composer.sync();
    var s = h.composer.settings;
    if (!s.setValue(std.mem.span(key), value)) return -1;
    h.composer.setSettings(s) catch return -1;
    return 0;
}

/// How many personal-dictionary words there are, after re-reading them.
pub export fn byakaron_userdict_count(composer: ?*ComposerHandle) usize {
    const h = composer orelse return 0;
    resetOut(h);
    h.composer.sync();
    return h.composer.user_words.words.items.len;
}

/// The `index`th personal-dictionary word (byte-sorted), or NULL past the end.
/// Valid until the next call on the composer other than this one.
pub export fn byakaron_userdict_word(composer: ?*ComposerHandle, index: usize) ?[*:0]const u8 {
    const h = composer orelse return null;
    const words = h.composer.user_words.words.items;
    if (index >= words.len) return null;
    return outString(h, words[index]);
}

// ── Settings manifest (src/Composer/Settings.zig) ───────────────────────────

const Settings = Composer.Settings;
const language_count = std.enums.values(Settings.Language).len;

pub const ByakaronSettingsSection = extern struct {
    id: [*:0]const u8,
    title: [*:0]const u8,
    hint: ?[*:0]const u8,
};

pub const ByakaronSettingsField = extern struct {
    key: [*:0]const u8,
    section: usize,
    control: c_int,
    title: [*:0]const u8,
    hint: ?[*:0]const u8,
    min: c_int,
    max: c_int,
    option_count: usize,
    option_values: [*]const [*:0]const u8,
    option_labels: [*]const [*:0]const u8,
    platforms: c_uint,
};

/// Each field's option values, and labels per language, as C string arrays.
const option_tables = blk: {
    const Tables = struct {
        values: []const [*:0]const u8,
        labels: [language_count][]const [*:0]const u8,
    };
    var tables: [Settings.manifest.len]Tables = undefined;
    for (Settings.manifest, &tables) |f, *t| {
        var values: [f.options.len][*:0]const u8 = undefined;
        for (f.options, &values) |o, *v| v.* = o.value.ptr;
        const final_values = values;
        t.values = &final_values;
        for (&t.labels, 0..) |*labels, l| {
            var ls: [f.options.len][*:0]const u8 = undefined;
            for (f.options, &ls) |o, *v| v.* = o.label[l].ptr;
            const final = ls;
            labels.* = &final;
        }
    }
    break :blk tables;
};

// byakaron.h's BYAKARON_PLATFORM_* bits.
comptime {
    for (.{ .{ .macos, 1 }, .{ .ios, 2 }, .{ .linux, 4 }, .{ .windows, 8 }, .{ .android, 16 }, .{ .web, 32 } }) |p| {
        if (Settings.Platform.bit(p[0]) != p[1]) @compileError("BYAKARON_PLATFORM_* differs from Settings.Platform");
    }
}

fn languageOf(lang: ?[*:0]const u8) usize {
    return @backingInt(Settings.language(if (lang) |p| std.mem.span(p) else ""));
}

pub export fn byakaron_settings_section_count() usize {
    return Settings.sections.len;
}

pub export fn byakaron_settings_section_info(index: usize, lang: ?[*:0]const u8, out: ?*ByakaronSettingsSection) c_int {
    const o = out orelse return -1;
    if (index >= Settings.sections.len) return -1;
    const s = Settings.sections[index];
    const l = languageOf(lang);
    o.* = .{ .id = s.id.ptr, .title = s.title[l].ptr, .hint = if (s.hint) |t| t[l].ptr else null };
    return 0;
}

pub export fn byakaron_settings_field_count() usize {
    return Settings.manifest.len;
}

pub export fn byakaron_settings_field_info(index: usize, lang: ?[*:0]const u8, out: ?*ByakaronSettingsField) c_int {
    const o = out orelse return -1;
    if (index >= Settings.manifest.len) return -1;
    const f = Settings.manifest[index];
    const l = languageOf(lang);
    const t = option_tables[index];
    o.* = .{
        .key = f.key.ptr,
        .section = f.section,
        .control = @backingInt(f.control),
        .title = f.title[l].ptr,
        .hint = if (f.hint) |h| h[l].ptr else null,
        .min = f.min,
        .max = f.max,
        .option_count = f.options.len,
        .option_values = t.values.ptr,
        .option_labels = t.labels[l].ptr,
        .platforms = f.platforms,
    };
    return 0;
}

// —— Updates (src/Update.zig) ——

const Update = Composer.Update;

/// byakaron.h's ByakaronRelease.
pub const ByakaronRelease = extern struct {
    tag: ?[*:0]u8 = null,
    version: ?[*:0]u8 = null,
    url: ?[*:0]u8 = null,
    sha256: ?[*:0]u8 = null,
    page: ?[*:0]u8 = null,
    size: u64 = 0,
    channel: c_int = -1,
};

/// The version this library was built as: "27.0.0", "27.0.0-beta.3", or a
/// local build's "27.0.0-dev". Static; do not free.
pub export fn byakaron_version() [*:0]const u8 {
    return @ptrCast(build_version_z);
}
const build_version_z = Update.build_version ++ "\x00";

/// This build's channel (BYAKARON_CHANNEL_*), or -1 for a local build.
pub export fn byakaron_update_build_channel() c_int {
    return if (Update.build_channel) |c| @backingInt(c) else -1;
}

/// The release feed to fetch: $BYAKARON_UPDATE_FEED when set (tests), else
/// GitHub's release list of nuhulabs/Byakaron-Assets. Do not free.
pub export fn byakaron_update_feed_url() [*:0]const u8 {
    if (std.c.getenv("BYAKARON_UPDATE_FEED")) |env| if (env[0] != 0) return env;
    return Update.feed_url;
}

/// The release `current` (NULL: this build) should update to on `channel`,
/// with `asset` (its file name on the release). 1 and `out` filled (free with
/// byakaron_update_free), 0 when there is none, -1 when the feed or version
/// is not understood.
pub export fn byakaron_update_pick(
    feed_json: ?[*:0]const u8,
    current: ?[*:0]const u8,
    channel: c_int,
    asset: ?[*:0]const u8,
    out: ?*ByakaronRelease,
) c_int {
    const o = out orelse return -1;
    o.* = .{};
    const feed = feed_json orelse return -1;
    const name = asset orelse return -1;
    if (channel < 0 or channel > @backingInt(Update.Channel.internal)) return -1;
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const found = Update.pick(
        arena.allocator(),
        std.mem.span(feed),
        if (current) |c| std.mem.span(c) else Update.build_version,
        @fromBackingInt(@intCast(channel)),
        std.mem.span(name),
    ) catch return -1;
    const p = found orelse return 0;
    const a = std.heap.c_allocator;
    o.* = .{
        .tag = dupeCString(a, p.tag),
        .version = dupeCString(a, p.version),
        .url = dupeCString(a, p.url),
        .sha256 = if (p.sha256) |h| dupeCString(a, h) else null,
        .page = dupeCString(a, p.page),
        .size = p.size,
        .channel = @backingInt(p.channel),
    };
    if (o.tag == null or o.version == null or o.url == null or o.page == null or (p.sha256 != null and o.sha256 == null)) {
        byakaron_update_free(o);
        return -1;
    }
    return 1;
}

/// Free what byakaron_update_pick filled in, and clear it. NULL is ignored.
pub export fn byakaron_update_free(update: ?*ByakaronRelease) void {
    const u = update orelse return;
    inline for (.{ "tag", "version", "url", "sha256", "page" }) |field| byakaron_string_free(@field(u, field));
    u.* = .{};
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

test {
    _ = @import("CFileStore.zig");
}

test "next words: sorted for the binary search, and found for a common word" {
    for (next_words[1..], next_words[0 .. next_words.len - 1]) |e, prev| {
        try std.testing.expect(std.mem.order(u8, prev.word, e.word) == .lt);
    }
    var out: [3][*:0]const u8 = undefined;
    const n = byakaron_next_words("আমি", &out, out.len);
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(usize, 0), byakaron_next_words("xyzzy", &out, out.len));
}

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
    try testing.expectEqualStrings("ভালো", std.mem.span(st.preedit));
    try testing.expect(st.candidate_count > 1);
    try testing.expectEqualStrings("ভালো", std.mem.span(st.candidates[0]));

    const r = byakaron_composer_key(c, 1, 0, 0); // space
    try testing.expectEqual(@as(c_int, 1), r.handled);
    try testing.expectEqualStrings("ভালো ", std.mem.span(r.commit));

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

    // The update channel: unpicked follows this build.
    var v_channel: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, "update_channel", &v_channel));
    try testing.expectEqual(@as(c_int, @backingInt(Update.default_channel)), v_channel);
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, "auto_update", &v_channel));
    try testing.expectEqual(@as(c_int, 1), v_channel);

    // One setting at a time, by key; the manifest says what to draw.
    var v: c_int = -1;
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, "suggestions", &v));
    try testing.expectEqual(@as(c_int, 0), v);
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_set(c, "candidates_per_page", 4));
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, "candidates_per_page", &v));
    try testing.expectEqual(@as(c_int, 4), v);
    try testing.expectEqual(@as(c_int, -1), byakaron_setting_set(c, "nope", 1));
    try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, "suggestions", &v));
    try testing.expectEqual(@as(c_int, 0), v); // the per-page change kept it
    var field: ByakaronSettingsField = undefined;
    var found_orientation = false;
    for (0..byakaron_settings_field_count()) |i| {
        try testing.expectEqual(@as(c_int, 0), byakaron_settings_field_info(i, "bn_BD.UTF-8", &field));
        try testing.expect(field.section < byakaron_settings_section_count());
        try testing.expectEqual(@as(c_int, 0), byakaron_setting_get(c, field.key, &v));
        if (std.mem.eql(u8, std.mem.span(field.key), "candidate_orientation")) {
            found_orientation = true;
            try testing.expectEqual(@as(usize, 2), field.option_count);
            try testing.expectEqualStrings("vertical", std.mem.span(field.option_values[1]));
            try testing.expectEqualStrings("উল্লম্ব", std.mem.span(field.option_labels[1]));
            try testing.expectEqual(@as(c_uint, 0), field.platforms & 2); // not iOS
        }
    }
    try testing.expect(found_orientation);
    try testing.expectEqual(@as(c_int, -1), byakaron_settings_field_info(99, null, &field));
    var section: ByakaronSettingsSection = undefined;
    try testing.expectEqual(@as(c_int, 0), byakaron_settings_section_info(0, null, &section));
    try testing.expectEqualStrings("Typing", std.mem.span(section.title));

    try testing.expectEqual(@as(c_int, 1), byakaron_userdict_add(c, "আকাশ"));
    try testing.expectEqual(@as(c_int, 1), byakaron_userdict_add(c, "অজানা"));
    try testing.expectEqual(@as(usize, 2), byakaron_userdict_count(c));
    try testing.expectEqualStrings("অজানা", std.mem.span(byakaron_userdict_word(c, 0).?));
    try testing.expectEqualStrings("আকাশ", std.mem.span(byakaron_userdict_word(c, 1).?));
    try testing.expectEqual(@as(?[*:0]const u8, null), byakaron_userdict_word(c, 2));

    // A second composer on the same directory sees the saved settings.
    const d = byakaron_composer_create(dir.ptr, null, null, null) orelse return error.CreateFailed;
    defer byakaron_composer_destroy(d);
    for ("bhalo") |ch| _ = byakaron_composer_key(d, 0, ch, 0);
    byakaron_composer_state(d, &st);
    try testing.expectEqual(@as(c_int, 0), st.panel_visible);
}

test "update ABI: pick, free, this build" {
    const testing = std.testing;
    const feed =
        \\[{"tag_name":"v99.0.0-beta.1","published_at":"2026-11-02T00:00:00Z","html_url":"page",
        \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/Byakaron.dmg","size":7,
        \\    "digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]},
        \\ {"tag_name":"v99.0.0","published_at":"2026-11-01T00:00:00Z","html_url":"p","assets":[]}]
    ;
    var u: ByakaronRelease = .{};
    try testing.expectEqual(@as(c_int, 1), byakaron_update_pick(feed, "27.0.0", 1, "Byakaron.dmg", &u));
    try testing.expectEqualStrings("v99.0.0-beta.1", std.mem.span(u.tag.?));
    try testing.expectEqualStrings("99.0.0-beta.1", std.mem.span(u.version.?));
    try testing.expectEqualStrings("https://x/Byakaron.dmg", std.mem.span(u.url.?));
    try testing.expectEqual(@as(usize, 64), std.mem.span(u.sha256.?).len);
    try testing.expectEqual(@as(u64, 7), u.size);
    try testing.expectEqual(@as(c_int, 1), u.channel);
    byakaron_update_free(&u);
    try testing.expectEqual(@as(?[*:0]u8, null), u.tag);
    byakaron_update_free(null);

    try testing.expectEqual(@as(c_int, 0), byakaron_update_pick(feed, "27.0.0", 0, "Byakaron.dmg", &u));
    try testing.expectEqual(@as(c_int, -1), byakaron_update_pick("{}", "27.0.0", 0, "Byakaron.dmg", &u));
    try testing.expectEqual(@as(c_int, -1), byakaron_update_pick(feed, "27.0.0", 4, "Byakaron.dmg", &u));
    try testing.expectEqual(@as(c_int, -1), byakaron_update_pick(feed, null, 0, null, &u));
    // NULL is this build, which is older than 99.
    try testing.expectEqual(@as(c_int, 1), byakaron_update_pick(feed, null, 3, "Byakaron.dmg", &u));
    byakaron_update_free(&u);

    try testing.expectEqualStrings(Update.build_version, std.mem.span(byakaron_version()));
    try testing.expectEqual(if (Update.build_channel) |ch| @as(c_int, @backingInt(ch)) else -1, byakaron_update_build_channel());
    try testing.expect(std.mem.startsWith(u8, std.mem.span(byakaron_update_feed_url()), "https://"));
}
