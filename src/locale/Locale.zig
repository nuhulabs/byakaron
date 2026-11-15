//! The shared UI labels: one `.zon` file per locale, each a flat struct of
//! `.key = "text"`. `en` is the reference: every other locale must have
//! exactly its keys. src/build/locale.zig generates each platform's strings
//! from these; `zig build test` checks the keys.
//!
//! To add a locale, add `<code>.zon` next to `en.zon` and list it in `files`.

const std = @import("std");

/// Every locale file, the reference (`en`) first. The code is the file's name
/// and the Android resource qualifier (`values-<code>`).
pub const files = [_]File{
    .{ .code = "en", .source = @embedFile("en.zon") },
    .{ .code = "bn", .source = @embedFile("bn.zon") },
};

pub const File = struct {
    code: []const u8,
    source: [:0]const u8,
};

pub const Entry = struct {
    key: []const u8,
    text: []const u8,
};

/// A locale's entries, in file order.
pub const Table = []const Entry;

pub const ParseError = error{ ParseZon, NotAStruct, NotAString, BadKey } || std.mem.Allocator.Error;

/// Parse a locale file into its entries. Strings are allocated in `arena`.
pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) ParseError!Table {
    var ast = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    defer ast.deinit(arena);
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    defer zoir.deinit(arena);
    if (ast.errors.len > 0 or zoir.hasCompileErrors()) return error.ParseZon;

    const root = std.zig.Zoir.Node.Index.root.get(&zoir);
    const lit = switch (root) {
        .struct_literal => |s| s,
        .empty_literal => return &.{},
        else => return error.NotAStruct,
    };
    const entries = try arena.alloc(Entry, lit.names.len);
    for (lit.names, 0..) |name, i| {
        const key = try arena.dupe(u8, name.get(&zoir));
        if (!validKey(key)) return error.BadKey;
        const text = switch (lit.vals.at(@intCast(i)).get(&zoir)) {
            .string_literal => |s| try arena.dupe(u8, s),
            else => return error.NotAString,
        };
        entries[i] = .{ .key = key, .text = text };
    }
    return entries;
}

/// Keys become C macros, Swift identifiers and Android resource names:
/// lower-case ASCII letters, digits and `_`, starting with a letter.
fn validKey(key: []const u8) bool {
    if (key.len == 0 or !std.ascii.isLower(key[0])) return false;
    for (key) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

pub const Mismatch = struct {
    /// A key of the reference that `other` lacks, or null.
    missing: ?[]const u8 = null,
    /// A key of `other` the reference lacks, or null.
    extra: ?[]const u8 = null,
};

/// The first key the two tables do not share, if any.
pub fn compare(reference: Table, other: Table) ?Mismatch {
    for (reference) |e| if (find(other, e.key) == null) return .{ .missing = e.key };
    for (other) |e| if (find(reference, e.key) == null) return .{ .extra = e.key };
    return null;
}

pub fn find(table: Table, key: []const u8) ?[]const u8 {
    for (table) |e| if (std.mem.eql(u8, e.key, key)) return e.text;
    return null;
}

/// Parse every locale in `files` and check each has exactly the reference's
/// keys. Logs the offending file and key.
pub fn loadAll(arena: std.mem.Allocator) ![]const Table {
    const tables = try arena.alloc(Table, files.len);
    for (files, tables) |f, *t| {
        t.* = parse(arena, f.source) catch |err| {
            std.log.err("src/locale/{s}.zon: {s}", .{ f.code, @errorName(err) });
            return err;
        };
    }
    for (files[1..], tables[1..]) |f, t| {
        if (compare(tables[0], t)) |m| {
            if (m.missing) |k| std.log.err("src/locale/{s}.zon: missing key .{s} (it is in {s}.zon)", .{ f.code, k, files[0].code });
            if (m.extra) |k| std.log.err("src/locale/{s}.zon: key .{s} is not in {s}.zon", .{ f.code, k, files[0].code });
            return error.LocaleKeysDiffer;
        }
    }
    return tables;
}

test "every locale file has every key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tables = try loadAll(arena.allocator());
    try std.testing.expect(tables[0].len > 0);
    for (tables) |t| {
        try std.testing.expectEqual(tables[0].len, t.len);
        for (t) |e| try std.testing.expect(e.text.len > 0);
    }
}

test "compare reports a missing and an extra key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const en = try parse(a, ".{ .add = \"Add\", .remove = \"Remove\" }");
    const short = try parse(a, ".{ .add = \"যোগ\" }");
    const long = try parse(a, ".{ .add = \"যোগ\", .remove = \"বাদ\", .clear = \"মুছুন\" }");
    try std.testing.expectEqualStrings("remove", compare(en, short).?.missing.?);
    try std.testing.expectEqualStrings("clear", compare(en, long).?.extra.?);
    try std.testing.expectEqual(null, compare(en, try parse(a, ".{ .remove = \"বাদ\", .add = \"যোগ\" }")));
}

test "parse rejects what the generators cannot emit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotAString, parse(a, ".{ .add = 1 }"));
    try std.testing.expectError(error.BadKey, parse(a, ".{ .Add = \"Add\" }"));
    // ZON itself rejects a repeated key.
    try std.testing.expectError(error.ParseZon, parse(a, ".{ .add = \"a\", .add = \"b\" }"));
    try std.testing.expectError(error.NotAStruct, parse(a, "\"Add\""));
}
