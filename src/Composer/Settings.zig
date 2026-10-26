//! The settings every Byakaron keyboard shares, on every platform: what the app
//! settings screens show and what `Composer` obeys. Stored as JSON
//! (`settings.json` in the data directory, or the web's kv); defaults follow
//! iAvro's preferences.plist where Avro has the setting.

const Settings = @This();

const std = @import("std");

pub const Orientation = enum { horizontal, vertical };

/// Bumped when a field changes meaning; `parse` migrates older files.
pub const current_version: u32 = 1;

pub const min_candidates_per_page = 3;
pub const max_candidates_per_page = 9;

version: u32 = current_version,
/// Avro dictionary mode (iAvro "IncludeDictionary"): candidates, autocorrect and
/// suffix forms. Off is plain phonetic mode: what is typed is transliterated
/// exactly, with no candidate list.
suggestions: bool = true,
/// After Avro's list, spelling corrections from Byakaron.db when Avro found no
/// dictionary word.
spelling_corrections: bool = true,
/// Remember the candidate chosen for an input and highlight it next time.
learn_choices: bool = true,
/// Digits typed outside a word become Bangla digits (০–৯); off keeps 0–9.
bangla_digits: bool = true,
/// Enter commits the word and also starts a new line (iAvro
/// "CommitNewLineOnEnter"); off commits only.
newline_on_enter: bool = false,
candidate_orientation: Orientation = .horizontal,
candidates_per_page: u8 = max_candidates_per_page,

/// Settings from JSON. Unknown fields are ignored, missing ones take their
/// default, and out-of-range values are clamped, so any older or newer file
/// still loads.
pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Settings {
    const parsed = try std.json.parseFromSlice(Settings, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    });
    defer parsed.deinit();
    var s = parsed.value;
    s.version = current_version;
    s.clamp();
    return s;
}

/// Settings as JSON (caller frees).
pub fn stringify(self: Settings, allocator: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
}

pub fn clamp(self: *Settings) void {
    self.candidates_per_page = std.math.clamp(self.candidates_per_page, min_candidates_per_page, max_candidates_per_page);
}

// ------------ TESTING ------------
const testing = std.testing;

test "defaults follow iAvro" {
    const s: Settings = .{};
    try testing.expect(s.suggestions); // IncludeDictionary = true
    try testing.expect(!s.newline_on_enter); // CommitNewLineOnEnter = false
    try testing.expectEqual(@as(u8, 9), s.candidates_per_page);
}

test "round trip" {
    const a = testing.allocator;
    const s: Settings = .{ .suggestions = false, .bangla_digits = false, .candidate_orientation = .vertical, .candidates_per_page = 5 };
    const json = try s.stringify(a);
    defer a.free(json);
    try testing.expectEqualDeep(s, try Settings.parse(a, json));
}

test "missing and unknown fields, clamping" {
    const a = testing.allocator;
    const s = try Settings.parse(a, "{\"suggestions\":false,\"future\":1,\"candidates_per_page\":40}");
    try testing.expect(!s.suggestions);
    try testing.expect(s.spelling_corrections);
    try testing.expectEqual(@as(u8, max_candidates_per_page), s.candidates_per_page);
    const low = try Settings.parse(a, "{\"candidates_per_page\":1}");
    try testing.expectEqual(@as(u8, min_candidates_per_page), low.candidates_per_page);
    try testing.expectError(error.UnexpectedEndOfInput, Settings.parse(a, "{"));
    try testing.expectError(error.SyntaxError, Settings.parse(a, "{]"));
}
