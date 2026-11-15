//! Build-time: src/locale/*.zon → each platform's strings.
//!
//!   locale <out-dir>
//!
//! writes into <out-dir>:
//! - `byakaron_strings.h`: a `BykStr` enum (`BYK_STR_<KEY>`), every locale's
//!   table, `byk_str_in (locale, id)` and `byk_str (id)` (the POSIX message
//!   locale). The Linux apps include it; the macOS app imports it through its
//!   bridging header and calls `byk_str_in` with the user's language.
//! - `Strings.zig`: `pub const <code> = struct { pub const <key> = "<text>"; }`
//!   per locale, and `default` (the reference). The web app imports it.
//! - `android/values[-<code>]/byakaron_strings.xml`: `R.string.byakaron_<key>`.
//!   The Android steps copy it into the keyboard's resources.
//!
//! The locale files are embedded in the `locale` module (src/locale/Locale.zig),
//! which also fails the build when a locale's keys differ from en's.

const std = @import("std");
const Locale = @import("locale");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <out-dir>\n", .{args[0]});
        return error.InvalidArguments;
    }
    const tables = try Locale.loadAll(arena);

    var out = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "byakaron_strings.h", .data = try header(arena, tables) });
    try out.writeFile(io, .{ .sub_path = "Strings.zig", .data = try zig(arena, tables) });
    for (Locale.files, tables, 0..) |f, t, i| {
        const dir = if (i == 0) "android/values" else try std.fmt.allocPrint(arena, "android/values-{s}", .{f.code});
        try out.createDirPath(io, dir);
        const path = try std.fmt.allocPrint(arena, "{s}/byakaron_strings.xml", .{dir});
        try out.writeFile(io, .{ .sub_path = path, .data = try android(arena, t) });
    }
}

const notice = "Generated from the .zon files in src/locale by src/build/locale.zig. Do not edit.";

fn header(arena: std.mem.Allocator, tables: []const Locale.Table) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    try o.print(
        \\/* {s} */
        \\#ifndef BYAKARON_STRINGS_H
        \\#define BYAKARON_STRINGS_H
        \\
        \\#include <locale.h>
        \\#include <stdlib.h>
        \\#include <string.h>
        \\
        \\typedef enum {{
        \\
    , .{notice});
    for (tables[0]) |e| {
        try o.writeAll("    BYK_STR_");
        try upper(o, e.key);
        try o.writeAll(",\n");
    }
    try o.writeAll("    BYK_STR_COUNT\n} BykStr;\n\ntypedef enum {\n");
    for (Locale.files) |f| {
        try o.writeAll("    BYK_LOCALE_");
        try upper(o, f.code);
        try o.writeAll(",\n");
    }
    try o.writeAll(
        \\    BYK_LOCALE_COUNT
        \\} BykLocale;
        \\
        \\/* The locale for a language tag ("bn", "bn_BD.UTF-8", "bn-IN"); the first
        \\ * (English) when there is none for it. */
        \\static inline BykLocale
        \\byk_locale_for (const char *lang)
        \\{
        \\    static const char *const codes[BYK_LOCALE_COUNT] = {
        \\
    );
    for (Locale.files) |f| try o.print("        \"{s}\",\n", .{f.code});
    try o.writeAll(
        \\    };
        \\    if (lang == NULL)
        \\        return (BykLocale) 0;
        \\    for (int i = 1; i < BYK_LOCALE_COUNT; i++) {
        \\        const size_t n = strlen (codes[i]);
        \\        if (strncmp (lang, codes[i], n) != 0)
        \\            continue;
        \\        const char end = lang[n];
        \\        if (end == '\0' || end == '_' || end == '-' || end == '.' || end == '@' || end == ':')
        \\            return (BykLocale) i;
        \\    }
        \\    return (BykLocale) 0;
        \\}
        \\
        \\/* A label in `locale`. */
        \\static inline const char *
        \\byk_str_in (BykLocale locale, BykStr id)
        \\{
        \\    static const char *const table[BYK_LOCALE_COUNT][BYK_STR_COUNT] = {
        \\
    );
    for (Locale.files, tables) |f, t| {
        try o.print("        {{ /* {s} */\n", .{f.code});
        for (tables[0]) |ref| {
            try o.writeAll("            \"");
            for (Locale.find(t, ref.key).?) |c| switch (c) {
                '"', '\\' => try o.print("\\{c}", .{c}),
                '\n' => try o.writeAll("\\n"),
                else => try o.writeByte(c),
            };
            try o.writeAll("\",\n");
        }
        try o.writeAll("        },\n");
    }
    try o.writeAll(
        \\    };
        \\    if ((int) locale < 0 || locale >= BYK_LOCALE_COUNT)
        \\        locale = (BykLocale) 0;
        \\    return table[locale][id];
        \\}
        \\
        \\/* A label in the POSIX message locale: LANGUAGE's first entry, else
        \\ * LC_ALL / LC_MESSAGES / LANG as setlocale() resolved them (GTK calls
        \\ * setlocale (LC_ALL, "") at startup). macOS passes its own language to
        \\ * byk_str_in instead. */
        \\static inline const char *
        \\byk_str (BykStr id)
        \\{
        \\    const char *lang = getenv ("LANGUAGE");
        \\    if (lang == NULL || lang[0] == '\0')
        \\#ifdef LC_MESSAGES
        \\        lang = setlocale (LC_MESSAGES, NULL);
        \\#else
        \\        lang = setlocale (LC_ALL, NULL);
        \\#endif
        \\    return byk_str_in (byk_locale_for (lang), id);
        \\}
        \\
        \\#endif /* BYAKARON_STRINGS_H */
        \\
    );
    return w.written();
}

fn upper(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(if (c == '-') '_' else std.ascii.toUpper(c));
}

fn zig(arena: std.mem.Allocator, tables: []const Locale.Table) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print("//! {s}\n\npub const default = {s};\n", .{ notice, Locale.files[0].code });
    for (Locale.files, tables) |f, t| {
        try w.writer.print("\npub const {f} = struct {{\n", .{std.zig.fmtId(f.code)});
        for (t) |e| try w.writer.print("    pub const {f} = \"{f}\";\n", .{ std.zig.fmtId(e.key), std.zig.fmtString(e.text) });
        try w.writer.writeAll("};\n");
    }
    return w.written();
}

fn android(arena: std.mem.Allocator, table: Locale.Table) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- {s} -->
        \\<resources>
        \\
    , .{notice});
    for (table) |e| {
        try w.writer.print("    <string name=\"byakaron_{s}\">", .{e.key});
        for (e.text, 0..) |c, i| switch (c) {
            '&' => try w.writer.writeAll("&amp;"),
            '<' => try w.writer.writeAll("&lt;"),
            '>' => try w.writer.writeAll("&gt;"),
            '\'', '"', '\\' => try w.writer.print("\\{c}", .{c}),
            '\n' => try w.writer.writeAll("\\n"),
            '@', '?' => if (i == 0) try w.writer.print("\\{c}", .{c}) else try w.writer.writeByte(c),
            else => try w.writer.writeByte(c),
        };
        try w.writer.writeAll("</string>\n");
    }
    try w.writer.writeAll("</resources>\n");
    return w.written();
}
