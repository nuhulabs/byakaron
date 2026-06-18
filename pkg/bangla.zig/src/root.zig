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

test {
    _ = @import("transliteration/transliteration.zig");
    _ = @import("tokenization/tokenizer.zig");
}
