//! Test-only reference: iAvro's `AvroParser.parse` (github.com/omicronlab/iAvro,
//! AvroParser.m), ported line by line and driven by iAvro's own `data.json`.
//! `Transliteration` (`.avro`) must produce exactly what this does; the parity
//! test at the bottom checks that over every dictionary word.
//!
//! Kept deliberately literal, quirks included: patterns are found by iAvro's
//! binary search (ordered by length, longest first, then by string), and
//! `isExact` requires `end < length`.

const Reference = @This();

const std = @import("std");

vowel: []const u8,
consonant: []const u8,
casesensitive: []const u8,
patterns: []const std.json.Value,
max_pattern_len: usize,

pub fn init(arena: std.mem.Allocator, data_json: []const u8) !Reference {
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, data_json, .{})).object;
    const patterns = root.get("patterns").?.array.items;
    return .{
        .vowel = root.get("vowel").?.string,
        .consonant = root.get("consonant").?.string,
        .casesensitive = root.get("casesensitive").?.string,
        .patterns = patterns,
        .max_pattern_len = patterns[0].object.get("find").?.string.len,
    };
}

fn smallCap(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c - 'A' + 'a' else c;
}

fn in(set: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, set, smallCap(c)) != null;
}

fn isVowel(self: Reference, c: u8) bool {
    return in(self.vowel, c);
}
fn isConsonant(self: Reference, c: u8) bool {
    return in(self.consonant, c);
}
fn isPunctuation(self: Reference, c: u8) bool {
    return !(self.isVowel(c) or self.isConsonant(c));
}

fn isExact(needle: []const u8, heystack: []const u8, start: isize, end: isize, not: bool) bool {
    const len: isize = @intCast(heystack.len);
    const hit = start >= 0 and end < len and std.mem.eql(u8, heystack[@intCast(start)..@intCast(end)], needle);
    return hit != not;
}

fn truthy(v: ?std.json.Value) bool {
    const s = (v orelse return false).string;
    return std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "true");
}

/// `AvroParser.parse` for ASCII input.
pub fn parse(self: Reference, allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    // fix: lowercase all but the case-sensitive letters.
    const fixed = try allocator.alloc(u8, string.len);
    defer allocator.free(fixed);
    for (string, fixed) |c, *f| f.* = if (in(self.casesensitive, c)) c else smallCap(c);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const len: isize = @intCast(fixed.len);
    var cur: isize = 0;
    while (cur < len) : (cur += 1) {
        const start = cur;
        var matched = false;
        var chunk_len: isize = @intCast(self.max_pattern_len);
        while (chunk_len > 0) : (chunk_len -= 1) {
            const end = start + chunk_len;
            if (end <= len) {
                const chunk = fixed[@intCast(start)..@intCast(end)];
                // Binary search
                var left: isize = 0;
                var right: isize = @as(isize, @intCast(self.patterns.len)) - 1;
                while (right >= left) {
                    const mid = @divTrunc(right + left, 2);
                    const pattern = self.patterns[@intCast(mid)].object;
                    const find = pattern.get("find").?.string;
                    if (std.mem.eql(u8, find, chunk)) {
                        const rules: []const std.json.Value = if (pattern.get("rules")) |r| r.array.items else &.{};
                        for (rules) |rule_v| {
                            const rule = rule_v.object;
                            var replace = true;
                            for (rule.get("matches").?.array.items) |match_v| {
                                const match = match_v.object;
                                const value = if (match.get("value")) |v| v.string else "";
                                const typ = match.get("type").?.string;
                                const scope = if (match.get("scope")) |s| s.string else "";
                                const negative = truthy(match.get("negative"));
                                const suffix = std.mem.eql(u8, typ, "suffix");
                                const prefix = !suffix;
                                const chk: isize = if (suffix) end else start - 1;

                                if (std.mem.eql(u8, scope, "punctuation")) {
                                    const ok = (chk < 0 and prefix) or (chk >= len and suffix) or self.isPunctuation(fixed[@intCast(chk)]);
                                    if (!ok != negative) {
                                        replace = false;
                                        break;
                                    }
                                } else if (std.mem.eql(u8, scope, "vowel")) {
                                    const ok = ((chk >= 0 and prefix) or (chk < len and suffix)) and self.isVowel(fixed[@intCast(chk)]);
                                    if (!ok != negative) {
                                        replace = false;
                                        break;
                                    }
                                } else if (std.mem.eql(u8, scope, "consonant")) {
                                    const ok = ((chk >= 0 and prefix) or (chk < len and suffix)) and self.isConsonant(fixed[@intCast(chk)]);
                                    if (!ok != negative) {
                                        replace = false;
                                        break;
                                    }
                                } else if (std.mem.eql(u8, scope, "exact")) {
                                    const vlen: isize = @intCast(value.len);
                                    const s: isize = if (suffix) end else start - vlen;
                                    const e: isize = if (suffix) end + vlen else start;
                                    if (!isExact(value, fixed, s, e, negative)) {
                                        replace = false;
                                        break;
                                    }
                                }
                            }
                            if (replace) {
                                try output.appendSlice(allocator, rule.get("replace").?.string);
                                cur = end - 1;
                                matched = true;
                                break;
                            }
                        }
                        if (matched) break;
                        // Default
                        try output.appendSlice(allocator, pattern.get("replace").?.string);
                        cur = end - 1;
                        matched = true;
                        break;
                    } else if (find.len > chunk.len or (find.len == chunk.len and std.mem.order(u8, find, chunk) == .lt)) {
                        left = mid + 1;
                    } else {
                        right = mid - 1;
                    }
                }
                if (matched) break;
            }
        }
        if (!matched) try output.append(allocator, fixed[@intCast(cur)]);
    }
    return output.toOwnedSlice(allocator);
}

// ------------ PARITY ------------
const testing = std.testing;
const Transliteration = @import("Transliteration.zig");

test "Transliteration matches iAvro AvroParser on every dictionary word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ref = try Reference.init(arena, @embedFile("iavro_data"));

    var avro = Transliteration.init(testing.allocator, .avro);
    defer avro.deinit();
    var orva = Transliteration.init(testing.allocator, .orva);
    defer orva.deinit();

    // Latin inputs: every dictionary word written back in Avro (orva), plus the
    // phonetic autocorrect values.
    var inputs: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, @embedFile("avro_words"), '\n');
    while (words.next()) |w| {
        const latin = orva.transliterate(w);
        defer testing.allocator.free(latin);
        try inputs.append(arena, try arena.dupe(u8, latin));
    }
    var lines = std.mem.tokenizeAny(u8, @embedFile("autodict"), "\r\n");
    while (lines.next()) |line| {
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        try inputs.append(arena, std.mem.trim(u8, line[sp..], " \t"));
    }

    var mismatches: usize = 0;
    var checked: usize = 0;
    for (inputs.items) |latin| {
        if (latin.len == 0 or !isAscii(latin)) continue;
        checked += 1;
        const want = try ref.parse(arena, latin);
        const got = avro.transliterate(latin);
        defer testing.allocator.free(got);
        if (!std.mem.eql(u8, want, got)) {
            if (mismatches < 25) std.debug.print("mismatch {s}: iAvro {s}, ours {s}\n", .{ latin, want, got });
            mismatches += 1;
        }
    }
    if (mismatches > 0) std.debug.print("{d} of {d} inputs differ from iAvro\n", .{ mismatches, checked });
    try testing.expect(checked > 150_000);
    try testing.expectEqual(@as(usize, 0), mismatches);
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}
