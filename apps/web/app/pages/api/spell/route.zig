const std = @import("std");
const zx = @import("zx");
const spell = @import("../../spell.zig");
const schema = @import("schema.zig");

const max_words = 512;

pub fn POST(ctx: zx.RouteContext) !void {
    const req = zx.util.zxon.parse(schema.Request, ctx.arena, ctx.request.text() orelse "", .{}) catch {
        ctx.response.setStatus(.bad_request);
        return ctx.response.text("expected a zxon schema.Request");
    };
    if (req.words.len > max_words) {
        ctx.response.setStatus(.payload_too_large);
        return ctx.response.text("too many words");
    }

    const results = spell.checkWords(ctx.arena, req.words) catch |err| switch (err) {
        error.NoSpellDb => {
            ctx.response.setStatus(.service_unavailable);
            return ctx.response.text("spell database not loaded");
        },
        else => return err,
    };
    const out = try ctx.arena.alloc(schema.TokenResult, results.len);
    for (results, out) |r, *o| {
        const suggestions = try ctx.arena.alloc(schema.Suggestion, r.suggestions.len);
        for (r.suggestions, suggestions) |s, *d| d.* = .{ .word = s.word, .frequency = s.frequency, .distance = s.distance, .score = s.score };
        o.* = .{ .token = r.token, .known = r.known, .suggestions = suggestions };
    }

    var w: std.Io.Writer.Allocating = .init(ctx.arena);
    try zx.util.zxon.serialize(schema.Response{ .results = out }, &w.writer, .{});
    ctx.response.setHeader("content-type", schema.content_type);
    ctx.response.text(w.written());
}

pub fn GET(ctx: zx.RouteContext) !void {
    ctx.response.text("POST a zxon schema.Request");
}

pub const options: zx.RouteOptions = .{
    .rendering = .request,
};
