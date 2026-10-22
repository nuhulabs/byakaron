//! Bangla.zig - A Zig library for Bangla script transliteration
//!
//! This library provides efficient transliteration capabilities between Latin and Bangla scripts
//! using multiple systems including Avro Phonetic (Latin → Bangla) and Orva (Bangla → Latin).
//! The implementation uses a trie-based pattern matching system for fast and accurate
//! transliteration that handles the complexity of Bangla phonetics.
const std = @import("std");
const testing = std.testing;

pub const Transliteration = @import("transliteration");
pub const Tokenization = @import("tokenization");
pub const Spell = @import("spell");
pub const SpellSqlite = @import("Spell/Sqlite.zig");
pub const AutoComplete = @import("autocomplete");
pub const AutoCompleteMem = @import("autocomplete_mem");
pub const AutoCompleteSqlite = @import("AutoComplete/Sqlite.zig");
pub const Composer = @import("composer");
pub const TransliterationMode = Transliteration.Mode;

// Pull in the C-ABI FFI exports (and the JNI bridge on Android) so they are
// included when this module is built as a static/shared library.
comptime {
    _ = @import("ffi/ffi.zig");
    if (@import("builtin").abi.isAndroid()) _ = @import("ffi/jni.zig");
}

test {
    _ = @import("transliteration");
    _ = @import("tokenization");
    _ = @import("spell");
    _ = SpellSqlite;
    _ = @import("autocomplete");
    _ = AutoCompleteMem;
    _ = AutoCompleteSqlite;
}
