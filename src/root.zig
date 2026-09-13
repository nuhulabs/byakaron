//! Bangla.zig - A Zig library for Bangla script transliteration
//!
//! This library provides efficient transliteration capabilities between Latin and Bangla scripts
//! using multiple systems including Avro Phonetic (Latin → Bangla) and Orva (Bangla → Latin).
//! The implementation uses a trie-based pattern matching system for fast and accurate
//! transliteration that handles the complexity of Bangla phonetics.
const std = @import("std");
const testing = std.testing;

pub const Transliteration = @import("transliteration/transliteration.zig").Transliteration;
pub const Tokenization = @import("tokenization");
pub const Spell = @import("spell");
pub const SpellSqlite = @import("Spell/Sqlite.zig");
pub const AutoComplete = @import("autocomplete");
pub const AutoCompleteMem = @import("AutoComplete/Mem.zig");
pub const AutoCompleteSqlite = @import("AutoComplete/Sqlite.zig");
pub const TransliterationMode = @import("transliteration/transliteration.zig").Mode;

// Pull in the C-ABI FFI and JNI exports
// so they are included when this module is built as a static/shared library.
comptime {
    _ = @import("ffi/ffi.zig");
    _ = @import("ffi/jni.zig");
}

test {
    _ = @import("transliteration/transliteration.zig");
    _ = @import("tokenization");
    _ = @import("spell");
    _ = SpellSqlite;
    _ = @import("autocomplete");
    _ = AutoCompleteMem;
    _ = AutoCompleteSqlite;
}
