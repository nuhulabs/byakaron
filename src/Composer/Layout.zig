//! The Avro Phonetic key map every Byakaron settings screen shows on its
//! Layout tab (macOS, Windows, Linux, web; byakaron.h's byakaron_layout_*).
//! One table, so every app shows the same keys. Every key here was typed
//! through the engine when the table was written; do the same when editing.

const std = @import("std");

pub const Entry = struct {
    bangla: [:0]const u8,
    /// One key sequence, or several separated by ", ".
    keys: [:0]const u8,
};

pub const Section = struct {
    title: [:0]const u8,
    entries: []const Entry,
};

/// Varga order, five to a row, the way the alphabet is taught.
const consonants = [_]Entry{
    .{ .bangla = "ক", .keys = "k" },      .{ .bangla = "খ", .keys = "kh" },    .{ .bangla = "গ", .keys = "g" },    .{ .bangla = "ঘ", .keys = "gh" },     .{ .bangla = "ঙ", .keys = "Ng" },
    .{ .bangla = "চ", .keys = "c" },      .{ .bangla = "ছ", .keys = "ch" },    .{ .bangla = "জ", .keys = "j" },    .{ .bangla = "ঝ", .keys = "jh" },     .{ .bangla = "ঞ", .keys = "NG" },
    .{ .bangla = "ট", .keys = "T" },      .{ .bangla = "ঠ", .keys = "Th" },    .{ .bangla = "ড", .keys = "D" },    .{ .bangla = "ঢ", .keys = "Dh" },     .{ .bangla = "ণ", .keys = "N" },
    .{ .bangla = "ত", .keys = "t" },      .{ .bangla = "থ", .keys = "th" },    .{ .bangla = "দ", .keys = "d" },    .{ .bangla = "ধ", .keys = "dh" },     .{ .bangla = "ন", .keys = "n" },
    .{ .bangla = "প", .keys = "p" },      .{ .bangla = "ফ", .keys = "ph, f" }, .{ .bangla = "ব", .keys = "b" },    .{ .bangla = "ভ", .keys = "bh, v" },  .{ .bangla = "ম", .keys = "m" },
    .{ .bangla = "য", .keys = "z" },      .{ .bangla = "র", .keys = "r" },     .{ .bangla = "ল", .keys = "l" },    .{ .bangla = "শ", .keys = "sh, S" },  .{ .bangla = "ষ", .keys = "Sh" },
    .{ .bangla = "স", .keys = "s" },      .{ .bangla = "হ", .keys = "h" },     .{ .bangla = "ড়", .keys = "R" },    .{ .bangla = "ঢ়", .keys = "Rh" },     .{ .bangla = "য়", .keys = "y, Y" },
    .{ .bangla = "ৎ", .keys = "t``" },    .{ .bangla = "ং", .keys = "ng" },    .{ .bangla = "ঃ", .keys = ":" },    .{ .bangla = "ঁ", .keys = "^" },
};

const vowels = [_]Entry{
    .{ .bangla = "অ", .keys = "o" },       .{ .bangla = "আ / কা", .keys = "a" }, .{ .bangla = "ই / কি", .keys = "i" },   .{ .bangla = "ঈ / কী", .keys = "I" },
    .{ .bangla = "উ / কু", .keys = "u" },  .{ .bangla = "ঊ / কূ", .keys = "U" }, .{ .bangla = "ঋ / কৃ", .keys = "rri" }, .{ .bangla = "এ / কে", .keys = "e" },
    .{ .bangla = "ঐ / কৈ", .keys = "OI" }, .{ .bangla = "ও / কো", .keys = "O" }, .{ .bangla = "ঔ / কৌ", .keys = "OU" },
};

/// Shown on an example rather than as a bare mark, so the key is unambiguous.
const special = [_]Entry{
    .{ .bangla = "ক্য য-ফলা", .keys = "ky, kZ" }, .{ .bangla = "ক্র র-ফলা", .keys = "kr" },  .{ .bangla = "ক্ব ব-ফলা", .keys = "kw" },
    .{ .bangla = "র্ক রেফ", .keys = "rrk" },      .{ .bangla = "ক্‌ হসন্ত", .keys = "k,," }, .{ .bangla = "কক, ক্ক নয়", .keys = "k`k" },
    .{ .bangla = "। দাড়ি", .keys = "." },        .{ .bangla = "৳ টাকা", .keys = "$" },
};

const numbers = [_]Entry{
    .{ .bangla = "০", .keys = "0" }, .{ .bangla = "১", .keys = "1" }, .{ .bangla = "২", .keys = "2" }, .{ .bangla = "৩", .keys = "3" }, .{ .bangla = "৪", .keys = "4" },
    .{ .bangla = "৫", .keys = "5" }, .{ .bangla = "৬", .keys = "6" }, .{ .bangla = "৭", .keys = "7" }, .{ .bangla = "৮", .keys = "8" }, .{ .bangla = "৯", .keys = "9" },
};

pub const sections = [_]Section{
    .{ .title = "Consonants (ব্যঞ্জনবর্ণ)", .entries = &consonants },
    .{ .title = "Vowels (স্বরবর্ণ)", .entries = &vowels },
    .{ .title = "Special (বিশেষ)", .entries = &special },
    .{ .title = "Numbers (সংখ্যা)", .entries = &numbers },
};

test "every section has entries with keys" {
    for (sections) |s| {
        try std.testing.expect(s.entries.len > 0);
        for (s.entries) |e| {
            try std.testing.expect(e.bangla.len > 0);
            try std.testing.expect(e.keys.len > 0);
        }
    }
}
