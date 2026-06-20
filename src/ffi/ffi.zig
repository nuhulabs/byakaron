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
