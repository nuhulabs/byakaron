//! Bangla.zig - A Zig library for Bangla script transliteration
//!
//! This library provides efficient transliteration capabilities between Latin and Bangla scripts
//! using multiple systems including Avro Phonetic (Latin → Bangla) and Orva (Bangla → Latin).
//! The implementation uses a trie-based pattern matching system for fast and accurate
//! transliteration that handles the complexity of Bangla phonetics.
const std = @import("std");
const testing = std.testing;

pub const Transliteration = @import("transliteration/transliteration.zig").Transliteration;
pub const Tokenization = @import("tokenization/tokenizer.zig");
pub const Spell = @import("Spell.zig");
pub const TransliterationMode = @import("transliteration/transliteration.zig").Mode;

// Pull in the C-ABI FFI exports (byakaron_transliterate / byakaron_string_free)
// so they are included when this module is built as a static/shared library.
comptime {
    _ = @import("ffi/ffi.zig");
}

test {
    _ = @import("transliteration/transliteration.zig");
    _ = @import("tokenization/tokenizer.zig");
}
