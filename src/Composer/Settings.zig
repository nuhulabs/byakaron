//! The settings every Byakaron keyboard shares, on every platform: what the app
//! settings screens show and what `Composer` obeys. Stored as JSON
//! (`settings.json` in the data directory, or the web's kv); defaults follow
//! iAvro's preferences.plist where Avro has the setting.
//!
//! `sections` and `manifest` describe the settings screen every app draws from
//! them: each setting's control, range or options, title and hint (in every
//! language of src/locale) and the platforms that show it. `value` and
//! `setValue` read and write a setting by its key, so no app parses this JSON.

const Settings = @This();

const std = @import("std");
const Update = @import("../Update.zig");

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
/// Enter commits the word and also goes to the app, which starts a new line
/// or sends (iAvro "CommitNewLineOnEnter"); off commits only. On by default,
/// unlike iAvro, so Enter sends a message with the word in it on every
/// platform, as a phone's Send key does.
newline_on_enter: bool = true,
candidate_orientation: Orientation = .horizontal,
candidates_per_page: u8 = max_candidates_per_page,
/// Strip mode for mobile keyboards: candidate panel stays active while composing,
/// even for single candidate results, and prefix autocompletions are included.
strip_mode: bool = false,
/// The desktop app checks for a newer Byakaron once a day and offers it.
auto_update: bool = true,
/// The releases the app updates to (Update.zig's `Channel`). Null until
/// someone picks one: the channel of the build that is installed, so a beta
/// download keeps getting betas.
update_channel: ?Update.Channel = null,

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
    // Internal was picked on an internal build, and this one is not.
    if (self.update_channel == .internal and !Update.internal_offered) self.update_channel = null;
}

/// The channel updates come from: the one picked, else this build's.
pub fn updateChannel(self: Settings) Update.Channel {
    return self.update_channel orelse Update.default_channel;
}

// —— Manifest: what a settings screen shows ——

/// The languages of src/locale (Locale.zig's `files`, in that order). Every
/// title and hint comes in each.
pub const Language = enum { en, bn };
const locale_tables = .{ @import("../locale/en.zon"), @import("../locale/bn.zon") };
const language_count = std.enums.values(Language).len;

/// The language for a tag ("bn", "bn_BD.UTF-8", "bn-IN"); English when there
/// is no locale for it.
pub fn language(tag: []const u8) Language {
    for (std.enums.values(Language)) |l| {
        const code = @tagName(l);
        if (!std.mem.startsWith(u8, tag, code)) continue;
        if (tag.len == code.len) return l;
        switch (tag[code.len]) {
            '_', '-', '.', '@', ':' => return l,
            else => {},
        }
    }
    return .en;
}

/// One label in every language, indexed by `Language`.
pub const Text = [language_count][:0]const u8;

fn text(comptime key: []const u8) Text {
    var t: Text = undefined;
    inline for (locale_tables, 0..) |table, i| t[i] = @field(table, key);
    return t;
}

fn optionalText(comptime key: []const u8) ?Text {
    return if (@hasField(@TypeOf(locale_tables[0]), key)) text(key) else null;
}

/// Where a setting is shown, as bits of `Field.platforms`.
pub const Platform = enum(u5) {
    macos,
    ios,
    linux,
    windows,
    android,
    web,

    pub fn bit(p: Platform) u32 {
        return @as(u32, 1) << @backingInt(p);
    }
};

fn platforms(comptime list: []const Platform) u32 {
    var mask: u32 = 0;
    for (list) |p| mask |= p.bit();
    return mask;
}

const everywhere = platforms(std.enums.values(Platform));
const desktop = platforms(&.{ .macos, .linux, .windows, .web });
/// The apps that update themselves (phones update from their stores, the web
/// is always new).
const self_updating = platforms(&.{ .macos, .linux, .windows });

pub const Control = enum(u8) {
    /// On or off (a bool field): 0 or 1.
    toggle,
    /// One of `options` (an enum field): the option's index.
    choice,
    /// A whole number from `min` to `max` (an integer field).
    number,
};

pub const Section = struct {
    id: [:0]const u8,
    title: Text,
    hint: ?Text,
};

pub const Option = struct {
    /// As stored in the JSON.
    value: [:0]const u8,
    label: Text,
};

pub const Field = struct {
    /// The field's name here and in the JSON.
    key: [:0]const u8,
    /// Index into `sections`.
    section: u8,
    control: Control,
    title: Text,
    hint: ?Text,
    options: []const Option,
    min: i32,
    max: i32,
    platforms: u32,

    pub fn shownOn(f: Field, p: Platform) bool {
        return f.platforms & p.bit() != 0;
    }
};

pub const sections = [_]Section{
    .{ .id = "typing", .title = text("typing"), .hint = text("typing_hint") },
    .{ .id = "candidates", .title = text("candidates"), .hint = text("candidates_hint") },
    .{ .id = "updates", .title = text("updates"), .hint = text("updates_hint") },
};

/// Fields no settings screen shows: the file's version, and what a keyboard
/// sets for itself (Android's `strip_mode`).
pub const internal = [_][]const u8{ "version", "strip_mode" };

/// Every setting a screen shows, in order. Titles are the locale's `<key>`,
/// hints `<key>_hint`, option labels the option's name; the control, range and
/// options follow the field's type.
pub const manifest = [_]Field{
    field("suggestions", 0, everywhere),
    // Needs Byakaron.db, which the iOS engine cannot open (see src/ffi/ffi.zig).
    field("spelling_corrections", 0, everywhere & ~Platform.ios.bit()),
    field("learn_choices", 0, everywhere),
    field("bangla_digits", 0, everywhere),
    field("newline_on_enter", 0, everywhere),
    // Phones show a bar, not a panel.
    field("candidate_orientation", 1, desktop),
    field("candidates_per_page", 1, everywhere),
    field("auto_update", 2, self_updating),
    field("update_channel", 2, self_updating),
};

fn field(comptime key: [:0]const u8, comptime section: u8, comptime shown: u32) Field {
    const T = @FieldType(Settings, key);
    var f: Field = .{
        .key = key,
        .section = section,
        .control = undefined,
        .title = text(key),
        .hint = optionalText(key ++ "_hint"),
        .options = &.{},
        .min = 0,
        .max = 1,
        .platforms = shown,
    };
    const Value = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    switch (@typeInfo(Value)) {
        .bool => f.control = .toggle,
        .@"enum" => {
            // Internal is offered only on an internal build; it is the last
            // channel, so the other options keep their index.
            const all = std.enums.values(Value);
            const tags = if (Value == Update.Channel and !Update.internal_offered) all[0 .. all.len - 1] else all;
            var options: [tags.len]Option = undefined;
            for (tags, &options) |tag, *o| o.* = .{ .value = @tagName(tag), .label = text(@tagName(tag)) };
            const final = options;
            f.control = .choice;
            f.options = &final;
            f.max = tags.len - 1;
        },
        .int => {
            f.control = .number;
            if (std.mem.eql(u8, key, "candidates_per_page")) {
                f.min = min_candidates_per_page;
                f.max = max_candidates_per_page;
            } else @compileError("give " ++ key ++ " its range");
        },
        else => @compileError("no control for " ++ key),
    }
    return f;
}

/// A setting a platform keeps itself, not in this JSON (iOS keeps these in its
/// app group's defaults, under `key` in camelCase), listed with `manifest` on
/// that platform's screen after its section's shared fields.
pub const PlatformField = struct {
    key: [:0]const u8,
    section: u8,
    control: Control,
    title: Text,
    hint: ?Text,
    options: []const Option,
    /// 0 or 1 for a toggle, the option's index for a choice.
    default: i32,
    platforms: u32,
};

pub const platform_fields = [_]PlatformField{
    .{
        .key = "english",
        .section = 0,
        .control = .toggle,
        .title = text("english"),
        .hint = text("english_hint"),
        .options = &.{},
        .default = 0,
        .platforms = Platform.ios.bit(),
    },
    .{
        .key = "emoji_key",
        .section = 0,
        .control = .choice,
        .title = text("emoji_key"),
        .hint = text("emoji_key_hint"),
        .options = &.{
            .{ .value = "automatic", .label = text("automatic") },
            .{ .value = "always", .label = text("always") },
            .{ .value = "never", .label = text("never") },
        },
        .default = 0,
        .platforms = Platform.ios.bit(),
    },
};

/// The note under an iOS settings screen: what follows the system's settings.
pub const ios_system_note = text("system_settings_hint");

/// A setting as a number: 0 or 1 for a toggle, the option's index for a
/// choice, the number itself. Null for a key not in `manifest`. An unpicked
/// `update_channel` is the channel it follows.
pub fn value(self: Settings, key: []const u8) ?i32 {
    inline for (manifest) |f| if (std.mem.eql(u8, f.key, key)) {
        const v = if (comptime std.mem.eql(u8, f.key, "update_channel")) self.updateChannel() else @field(self, f.key);
        return switch (f.control) {
            .toggle => @intFromBool(v),
            .choice => @backingInt(v),
            .number => v,
        };
    };
    return null;
}

/// Set a setting from a number (see `value`); a number out of range is
/// clamped. False for a key not in `manifest`.
pub fn setValue(self: *Settings, key: []const u8, v: i32) bool {
    inline for (manifest) |f| if (std.mem.eql(u8, f.key, key)) {
        const n = std.math.clamp(v, f.min, f.max);
        const T = switch (@typeInfo(@FieldType(Settings, f.key))) {
            .optional => |o| o.child,
            else => @FieldType(Settings, f.key),
        };
        @field(self, f.key) = switch (f.control) {
            .toggle => n != 0,
            .choice => @as(T, @fromBackingInt(@intCast(n))),
            .number => @as(T, @intCast(n)),
        };
        return true;
    };
    return false;
}

// ------------ TESTING ------------
const testing = std.testing;

test "the manifest covers every setting, and value/setValue round trip" {
    var covered: usize = 0;
    inline for (@typeInfo(Settings).@"struct".field_names) |name| {
        const skip = comptime for (internal) |i| {
            if (std.mem.eql(u8, i, name)) break true;
        } else false;
        if (skip) continue;
        var found = false;
        for (manifest) |f| found = found or std.mem.eql(u8, f.key, name);
        if (!found) std.log.err("{s} is not in the manifest", .{name});
        try testing.expect(found);
        covered += 1;
    }
    try testing.expectEqual(manifest.len, covered);

    var s: Settings = .{};
    try testing.expectEqual(@as(?i32, 1), s.value("suggestions"));
    try testing.expectEqual(@as(?i32, 9), s.value("candidates_per_page"));
    try testing.expectEqual(@as(?i32, null), s.value("version"));
    try testing.expect(s.setValue("suggestions", 0));
    try testing.expect(s.setValue("candidate_orientation", 1));
    try testing.expect(s.setValue("candidates_per_page", 40));
    try testing.expect(!s.setValue("nope", 1));
    try testing.expect(!s.suggestions);
    try testing.expectEqual(Orientation.vertical, s.candidate_orientation);
    try testing.expectEqual(@as(u8, max_candidates_per_page), s.candidates_per_page);
    try testing.expect(s.setValue("candidate_orientation", -3));
    try testing.expectEqual(Orientation.horizontal, s.candidate_orientation);
}

test "manifest text in each language, and the language for a tag" {
    try testing.expectEqual(Language.bn, language("bn_BD.UTF-8"));
    try testing.expectEqual(Language.bn, language("bn-IN"));
    try testing.expectEqual(Language.en, language("bnx"));
    try testing.expectEqual(Language.en, language("fr"));
    for (manifest) |f| {
        try testing.expect(f.section < sections.len);
        for (f.title) |t| try testing.expect(t.len > 0);
        if (f.control == .choice) try testing.expectEqual(f.options.len, @as(usize, @intCast(f.max + 1)));
    }
    const per_page = manifest[6];
    try testing.expectEqualStrings("Words per page", per_page.title[@backingInt(Language.en)]);
    try testing.expect(!manifest[1].shownOn(.ios));
    try testing.expect(manifest[0].shownOn(.ios));
}

test "defaults follow iAvro" {
    const s: Settings = .{};
    try testing.expect(s.suggestions); // IncludeDictionary = true
    try testing.expect(s.newline_on_enter); // iAvro's CommitNewLineOnEnter is false: Enter sends here
    try testing.expectEqual(@as(u8, 9), s.candidates_per_page);
}

test "update settings: on, following this build's channel until one is picked" {
    const a = testing.allocator;
    var s: Settings = .{};
    try testing.expect(s.auto_update);
    try testing.expectEqual(@as(?Update.Channel, null), s.update_channel);
    try testing.expectEqual(Update.default_channel, s.updateChannel());
    try testing.expectEqual(@as(?i32, @backingInt(Update.default_channel)), s.value("update_channel"));

    try testing.expect(s.setValue("update_channel", 1));
    try testing.expectEqual(Update.Channel.beta, s.update_channel.?);
    // Internal only where it is offered: past the last option clamps.
    try testing.expect(s.setValue("update_channel", 3));
    try testing.expectEqual(if (Update.internal_offered) Update.Channel.internal else Update.Channel.alpha, s.update_channel.?);

    const json = try s.stringify(a);
    defer a.free(json);
    try testing.expectEqualDeep(s, try Settings.parse(a, json));
    // An older file has no update fields; an unpicked channel stays unpicked.
    try testing.expectEqual(@as(?Update.Channel, null), (try Settings.parse(a, "{\"update_channel\":null}")).update_channel);
    try testing.expectEqual(@as(?Update.Channel, null), (try Settings.parse(a, "{}")).update_channel);
    const picked_internal = try Settings.parse(a, "{\"update_channel\":\"internal\"}");
    try testing.expectEqual(if (Update.internal_offered) @as(?Update.Channel, .internal) else null, picked_internal.update_channel);

    const channel = manifest[8];
    try testing.expectEqualStrings("update_channel", channel.key);
    try testing.expectEqual(Control.choice, channel.control);
    try testing.expectEqual(@as(usize, if (Update.internal_offered) 4 else 3), channel.options.len);
    try testing.expectEqualStrings("production", channel.options[0].value);
    try testing.expectEqualStrings("Stable", channel.options[0].label[0]);
    try testing.expect(channel.shownOn(.macos) and channel.shownOn(.windows) and channel.shownOn(.linux));
    try testing.expect(!channel.shownOn(.ios) and !channel.shownOn(.android) and !channel.shownOn(.web));
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
