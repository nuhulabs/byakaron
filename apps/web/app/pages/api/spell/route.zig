//! POST /api/spell — check Bangla text; returns token results + suggestions.

const std = @import("std");
const zx = @import("zx");
const spell = @import("../../spell.zig");

const RequestBody = struct {
    text: []const u8 = "",
};

const SuggestionOut = struct {
    word: []const u8,
    frequency: i64 = 0,
    distance: usize = 0,
    score: i64 = 0,
};

const TokenOut = struct {
    token: []const u8,
    known: bool,
    suggestions: []const SuggestionOut,
};

const ResponseBody = struct {
    results: []const TokenOut,
    word_count: usize,
    issue_count: usize,
};

pub fn POST(ctx: zx.RouteContext) !void {
    const body = try ctx.request.json(RequestBody, .{ .ignore_unknown_fields = true });
    const text = if (body) |b| std.mem.trim(u8, b.text, " \t\r\n") else "";

    if (text.len == 0) {
        try ctx.response.json(ResponseBody{
            .results = &.{},
            .word_count = 0,
            .issue_count = 0,
        }, .{});
        return;
    }

    const results = try spell.checkText(ctx.arena, text);
    var out: std.ArrayList(TokenOut) = .empty;
    var issue_count: usize = 0;

    for (results) |r| {
        var suggs: std.ArrayList(SuggestionOut) = .empty;
        for (r.suggestions) |s| {
            try suggs.append(ctx.arena, .{
                .word = s.word,
                .frequency = s.frequency,
                .distance = s.distance,
                .score = s.score,
            });
        }
        if (!r.known) issue_count += 1;
        try out.append(ctx.arena, .{
            .token = r.token,
            .known = r.known,
            .suggestions = try suggs.toOwnedSlice(ctx.arena),
        });
    }

    try ctx.response.json(ResponseBody{
        .results = try out.toOwnedSlice(ctx.arena),
        .word_count = results.len,
        .issue_count = issue_count,
    }, .{});
}

pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.response.json(.{
        .ok = true,
        .usage = "POST {\"text\":\"...\"}",
    }, .{});
}
