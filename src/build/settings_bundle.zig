//! Build-time: the settings manifest (src/Composer/Settings.zig) → the iOS
//! app's Settings.bundle, where iOS Settings shows Byakaron's settings.
//!
//!   settings_bundle <out-dir>
//!
//! writes `Root.plist` (the shared settings iOS shows, then iOS's own:
//! `platform_fields`) and `<code>.lproj/Root.strings` per locale. The plist's
//! titles are the English text, which iOS looks up in the strings files. Keys
//! are the manifest's in camelCase (`learn_choices` → `learnChoices`), where
//! the keyboard reads them (KeyboardSettings.swift).

const std = @import("std");
const Settings = @import("settings").Settings;

const ios = Settings.Platform.ios;
const en = @intFromEnum(Settings.Language.en);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <out-dir>\n", .{args[0]});
        return error.InvalidArguments;
    }
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer out.close(io);

    var texts: std.ArrayList(Settings.Text) = .empty;
    try out.writeFile(io, .{ .sub_path = "Root.plist", .data = try plist(arena, &texts) });
    for (std.enums.values(Settings.Language)) |lang| {
        const dir = try std.fmt.allocPrint(arena, "{s}.lproj", .{@tagName(lang)});
        try out.createDirPath(io, dir);
        const path = try std.fmt.allocPrint(arena, "{s}/Root.strings", .{dir});
        try out.writeFile(io, .{ .sub_path = path, .data = try strings(arena, texts.items, @intFromEnum(lang)) });
    }
}

/// One row of the iOS screen: a shared field or one of iOS's own.
const Row = struct {
    key: []const u8,
    control: Settings.Control,
    title: Settings.Text,
    hint: ?Settings.Text,
    options: []const Settings.Option,
    min: i32 = 0,
    max: i32 = 1,
    default: i32,
    /// Choice values are the option's name (iOS's own) or its index (shared).
    named_values: bool,
};

fn plist(arena: std.mem.Allocator, texts: *std.ArrayList(Settings.Text)) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    try o.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<!-- Generated from src/Composer/Settings.zig by src/build/settings_bundle.zig (zig build ios-settings). Do not edit. -->
        \\<plist version="1.0">
        \\<dict>
        \\  <key>ApplicationGroupContainerIdentifier</key>
        \\  <string>group.dev.nuhu.labs.KeyboardApp</string>
        \\  <key>PreferenceSpecifiers</key>
        \\  <array>
        \\
    );
    const defaults: Settings = .{};
    for (Settings.sections, 0..) |section, s| {
        var rows: std.ArrayList(Row) = .empty;
        for (Settings.manifest) |f| if (f.section == s and f.shownOn(ios)) try rows.append(arena, .{
            .key = f.key,
            .control = f.control,
            .title = f.title,
            .hint = f.hint,
            .options = f.options,
            .min = f.min,
            .max = f.max,
            .default = defaults.value(f.key).?,
            .named_values = false,
        });
        for (Settings.platform_fields) |f| if (f.section == s and f.platforms & ios.bit() != 0) try rows.append(arena, .{
            .key = f.key,
            .control = f.control,
            .title = f.title,
            .hint = f.hint,
            .options = f.options,
            .max = @intCast(f.options.len -| 1),
            .default = f.default,
            .named_values = true,
        });
        // A group per row, for the row's hint as its footer; the section's
        // title heads the first, its hint follows the last shared row's.
        var last_shared: ?usize = null;
        for (rows.items, 0..) |row, i| if (!row.named_values) {
            last_shared = i;
        };
        for (rows.items, 0..) |row, i| {
            const title: ?Settings.Text = if (i == 0) section.title else null;
            const last = last_shared == i;
            try group(arena, o, texts, title, row.hint, if (last) section.hint else null);
            try item(arena, o, texts, row);
        }
    }
    try group(arena, o, texts, null, Settings.ios_system_note, null);
    try o.writeAll(
        \\  </array>
        \\  <key>StringsTable</key>
        \\  <string>Root</string>
        \\</dict>
        \\</plist>
        \\
    );
    return w.written();
}

fn group(
    arena: std.mem.Allocator,
    o: *std.Io.Writer,
    texts: *std.ArrayList(Settings.Text),
    title: ?Settings.Text,
    hint: ?Settings.Text,
    more: ?Settings.Text,
) !void {
    try o.writeAll("\t\t<dict>\n");
    if (hint != null or more != null) {
        // Joined in every language, so the joined text is its own string.
        var footer: Settings.Text = undefined;
        for (&footer, 0..) |*t, l| {
            const parts = [_]?Settings.Text{ hint, more };
            var joined: std.ArrayList(u8) = .empty;
            for (parts) |part| if (part) |p| {
                if (joined.items.len > 0) try joined.append(arena, ' ');
                try joined.appendSlice(arena, p[l]);
            };
            t.* = try joined.toOwnedSliceSentinel(arena, 0);
        }
        try entry(o, "FooterText", footer[en]);
        try texts.append(arena, footer);
    }
    if (title) |t| {
        try entry(o, "Title", t[en]);
        try texts.append(arena, t);
    }
    try entry(o, "Type", "PSGroupSpecifier");
    try o.writeAll("\t\t</dict>\n");
}

fn item(arena: std.mem.Allocator, o: *std.Io.Writer, texts: *std.ArrayList(Settings.Text), row: Row) !void {
    try o.writeAll("\t\t<dict>\n");
    try o.writeAll("\t\t\t<key>DefaultValue</key>\n");
    switch (row.control) {
        .toggle => try o.print("\t\t\t<{s}/>\n", .{if (row.default != 0) "true" else "false"}),
        .choice => if (row.named_values)
            try o.print("\t\t\t<string>{s}</string>\n", .{row.options[@intCast(row.default)].value})
        else
            try o.print("\t\t\t<integer>{d}</integer>\n", .{row.default}),
        .number => try o.print("\t\t\t<integer>{d}</integer>\n", .{row.default}),
    }
    try entry(o, "Key", try camel(arena, row.key));
    try entry(o, "Title", row.title[en]);
    try texts.append(arena, row.title);
    if (row.control != .toggle) {
        try o.writeAll("\t\t\t<key>Titles</key>\n\t\t\t<array>\n");
        if (row.control == .choice) {
            for (row.options) |opt| {
                try o.writeAll("\t\t\t\t<string>");
                try escaped(o, opt.label[en]);
                try o.writeAll("</string>\n");
                try texts.append(arena, opt.label);
            }
        } else {
            var n = row.min;
            while (n <= row.max) : (n += 1) try o.print("\t\t\t\t<string>{d}</string>\n", .{n});
        }
        try o.writeAll("\t\t\t</array>\n");
    }
    try entry(o, "Type", switch (row.control) {
        .toggle => "PSToggleSwitchSpecifier",
        .choice, .number => "PSMultiValueSpecifier",
    });
    if (row.control != .toggle) {
        try o.writeAll("\t\t\t<key>Values</key>\n\t\t\t<array>\n");
        if (row.control == .choice and row.named_values) {
            for (row.options) |opt| try o.print("\t\t\t\t<string>{s}</string>\n", .{opt.value});
        } else {
            var n = row.min;
            while (n <= row.max) : (n += 1) try o.print("\t\t\t\t<integer>{d}</integer>\n", .{n});
        }
        try o.writeAll("\t\t\t</array>\n");
    }
    try o.writeAll("\t\t</dict>\n");
}

fn entry(o: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try o.print("\t\t\t<key>{s}</key>\n\t\t\t<string>", .{key});
    try escaped(o, value);
    try o.writeAll("</string>\n");
}

fn escaped(o: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try o.writeAll("&amp;"),
        '<' => try o.writeAll("&lt;"),
        '>' => try o.writeAll("&gt;"),
        else => try o.writeByte(c),
    };
}

/// `learn_choices` → `learnChoices`.
fn camel(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper = false;
    for (key) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        try out.append(arena, if (upper) std.ascii.toUpper(c) else c);
        upper = false;
    }
    return out.items;
}

/// `"<English>" = "<text in lang>";` for every text the plist uses, once each.
fn strings(arena: std.mem.Allocator, texts: []const Settings.Text, lang: usize) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    try o.writeAll("/* Generated from src/Composer/Settings.zig and src/locale by src/build/settings_bundle.zig. Do not edit. */\n");
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (texts) |t| {
        if ((try seen.getOrPut(arena, t[en])).found_existing) continue;
        try quoted(o, t[en]);
        try o.writeAll(" = ");
        try quoted(o, t[lang]);
        try o.writeAll(";\n");
    }
    return w.written();
}

fn quoted(o: *std.Io.Writer, s: []const u8) !void {
    try o.writeByte('"');
    for (s) |c| switch (c) {
        '"', '\\' => try o.print("\\{c}", .{c}),
        '\n' => try o.writeAll("\\n"),
        else => try o.writeByte(c),
    };
    try o.writeByte('"');
}
