//! Rewrite a transliteration grammar (rules.zon / orva.zon) in canonical form.
//!
//!   rules <in.zon> <out.zon>
//!
//! Parses the file as a `Grammar` and serializes it back with `std.zon`, which
//! writes Bangla as plain UTF-8 rather than `\xe0..` escapes, so the rules stay
//! readable and diffable. Run through `zig build rules`, which writes the result
//! back over the source files.

const std = @import("std");
const Grammar = @import("transliteration.zig").Grammar;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: {s} <in.zon> <out.zon>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const cwd = std.Io.Dir.cwd();
    const source = try cwd.readFileAllocOptions(io, args[1], arena, .limited(16 * 1024 * 1024), .of(u8), 0);

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const grammar = std.zon.parse.fromSlice(Grammar, .{
        .gpa = init.gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(args[1]);
        return err;
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(grammar, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
