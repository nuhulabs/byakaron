//! Spelling corrections for a `Composer`, shown after Avro's list when Avro
//! found no dictionary word. Asynchronous: `get` answers from what is ready and
//! otherwise starts work and returns null; when the result arrives the
//! implementation calls the composer's update callback, and the platform asks
//! the composer to `refresh`, which calls `get` again.
//!
//! Implementations: `SpellCorrector` (Byakaron.db on a worker thread) for native
//! keyboards; the web page fetches `/api/spell`.

const Corrector = @This();

ctx: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Corrections for `word` (not including the word), or null while they are
    /// being looked up. The slice is valid until the next call.
    get: *const fn (ctx: *anyopaque, word: []const u8) ?[]const []const u8,
};

pub fn get(self: Corrector, word: []const u8) ?[]const []const u8 {
    return self.vtable.get(self.ctx, word);
}
