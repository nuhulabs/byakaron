//! Shape of `lexicon.zon`: iAvro's dictionary, suffix and autocorrect tables,
//! written at build time by `src/build/lexicon.zig` from the pinned iAvro
//! `database.db3` and `autodict.dct`, and imported at compile time by
//! `AutoComplete/Mem.zig`. Every list is byte-sorted on its key so lookups are
//! binary searches over the compiled-in data.

/// Onset tables (`a`, `bh`, `khandatta`, …), sorted by name.
tables: []const Table,
/// Latin suffix → Bangla suffix, sorted by `latin`.
suffixes: []const Suffix,
/// autodict.dct entries, sorted by `from`.
autocorrect: []const Autocorrect,

pub const Table = struct {
    name: []const u8,
    /// Byte-sorted, distinct.
    words: []const []const u8,
};

pub const Suffix = struct {
    latin: []const u8,
    bangla: []const u8,
};

pub const Autocorrect = struct {
    from: []const u8,
    to: []const u8,
    /// `to` is Avro phonetic (transliterated when used); otherwise literal.
    phonetic: bool,
};
