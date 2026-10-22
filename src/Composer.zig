//! The Byakaron keyboard: one state machine every platform drives, so Linux,
//! macOS, Windows, Android and the web type exactly alike. A shell turns OS key
//! events into `Key`s, applies the returned `Outcome` (commit text, whether the
//! key was consumed) and draws `preedit` and the candidate page.
//!
//! Behaviour is OmicronLab Avro's (iAvro AvroKeyboardController):
//! - Typed ASCII accumulates in a Latin buffer; Avro's candidates for it
//!   (`AutoComplete.suggest`) are listed, the highlighted one is shown inline.
//! - Space commits the highlighted candidate and a space; Enter commits it
//!   (plus a new line with `newline_on_enter`); Tab and other keys commit it
//!   and pass through; Esc drops the word; Backspace edits the buffer.
//! - Arrows move the highlight (wrapping), Page Up/Down move a page, 1–9 pick
//!   on the current page. Moving the highlight teaches Avro the choice.
//! - With `suggestions` off (phonetic mode) the word is transliterated exactly,
//!   with no list.
//! After Avro's list come personal-dictionary words starting with the
//! transliteration and, when Avro found no dictionary word, spelling
//! corrections.

const Composer = @This();

const std = @import("std");
const AutoComplete = @import("autocomplete");
const AutoCompleteMem = @import("autocomplete_mem");
pub const Settings = @import("Composer/Settings.zig");
pub const Store = @import("Composer/Store.zig");
pub const FileStore = @import("Composer/FileStore.zig");
pub const UserWords = @import("Composer/UserWords.zig");
pub const Corrector = @import("Composer/Corrector.zig");

/// Personal-dictionary words listed after Avro's.
const user_word_limit = 5;
/// Spelling corrections listed when Avro has no dictionary word.
const correction_limit = 3;

pub const Key = union(enum) {
    /// A printable ASCII character (0x21–0x7e).
    char: u8,
    space,
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    /// Any other key (Home, Delete, function keys, …).
    other,
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Cmd / Super / Win.
    meta: bool = false,
    _: u4 = 0,

    fn shortcut(self: Modifiers) bool {
        return self.ctrl or self.alt or self.meta;
    }
};

pub const Outcome = struct {
    /// True if the key was consumed; false means the shell lets the
    /// application have the key too (after inserting `commit`).
    handled: bool,
    /// Text to insert before anything else (valid until the next call).
    commit: []const u8 = "",
};

gpa: std.mem.Allocator,
mem: *AutoCompleteMem,
store: Store,
corrector: ?Corrector,
settings: Settings = .{},
user_words: UserWords,

latin: std.ArrayList(u8) = .empty,
avro: ?AutoComplete.Candidates = null,
/// Avro's candidates, then personal-dictionary words, then corrections.
items: std.ArrayList([]const u8) = .empty,
/// Strings of the non-Avro items.
extras: std.heap.ArenaAllocator,
/// The first `avro_count` items are Avro's (the only ones it can learn).
avro_count: usize = 0,
highlight: usize = 0,
committed: std.ArrayList(u8) = .empty,
selections_dirty: bool = false,
/// Blobs as last read from or written to `store`, to notice outside changes.
seen: [3]?[]u8 = .{ null, null, null },

pub fn init(gpa: std.mem.Allocator, store: Store, corrector: ?Corrector) !Composer {
    var self: Composer = .{
        .gpa = gpa,
        .mem = try AutoCompleteMem.create(gpa),
        .store = store,
        .corrector = corrector,
        .user_words = .init(gpa),
        .extras = .init(gpa),
    };
    self.sync();
    return self;
}

pub fn deinit(self: *Composer) void {
    self.saveSelections();
    self.clearList();
    self.items.deinit(self.gpa);
    self.extras.deinit();
    self.latin.deinit(self.gpa);
    self.committed.deinit(self.gpa);
    self.user_words.deinit();
    for (&self.seen) |*s| if (s.*) |b| self.gpa.free(b);
    self.mem.destroy(self.gpa);
}

fn ac(self: *Composer) *AutoComplete {
    return self.mem.autoComplete();
}

// —— State the shell draws ——

pub fn composing(self: Composer) bool {
    return self.latin.items.len > 0;
}

/// The text shown inline while composing: the highlighted candidate.
pub fn preedit(self: Composer) []const u8 {
    if (!self.composing() or self.items.items.len == 0) return "";
    return self.items.items[self.highlight];
}

pub fn panelVisible(self: Composer) bool {
    return self.composing() and self.settings.suggestions and self.items.items.len > 1;
}

fn perPage(self: Composer) usize {
    return self.settings.candidates_per_page;
}

pub fn page(self: Composer) usize {
    return self.highlight / self.perPage();
}

pub fn pageCount(self: Composer) usize {
    return std.math.divCeil(usize, self.items.items.len, self.perPage()) catch 1;
}

/// The candidates on the current page.
pub fn pageItems(self: Composer) []const []const u8 {
    if (!self.panelVisible()) return &.{};
    const start = self.page() * self.perPage();
    return self.items.items[start..@min(start + self.perPage(), self.items.items.len)];
}

/// The highlighted candidate's index within `pageItems`.
pub fn pageHighlight(self: Composer) usize {
    return self.highlight % self.perPage();
}

/// The whole candidate list (Avro's, then the extras).
pub fn candidates(self: Composer) []const []const u8 {
    return self.items.items;
}

// —— Input ——

pub fn key(self: *Composer, k: Key, mods: Modifiers) !Outcome {
    self.committed.clearRetainingCapacity();
    if (mods.shortcut()) return self.commitAndPass();

    const word = self.composing();
    switch (k) {
        .char => |c| {
            if (c < 0x21 or c > 0x7e) return self.commitAndPass();
            if (self.panelVisible() and c >= '1' and c <= '9') {
                const i = c - '1';
                if (i < self.pageItems().len) return self.pick(i);
            }
            if (!word) {
                if (std.ascii.isDigit(c) and !self.settings.bangla_digits) return .{ .handled = false };
                self.sync();
            }
            try self.latin.append(self.gpa, c);
            try self.refresh();
            return .{ .handled = true };
        },
        .space => {
            if (!word) return .{ .handled = false };
            try self.commitHighlighted();
            try self.committed.append(self.gpa, ' ');
            return .{ .handled = true, .commit = self.committed.items };
        },
        .enter => {
            if (!word) return .{ .handled = false };
            try self.commitHighlighted();
            return .{ .handled = !self.settings.newline_on_enter, .commit = self.committed.items };
        },
        .backspace => {
            if (!word) return .{ .handled = false };
            _ = self.latin.pop();
            if (self.composing()) try self.refresh() else self.clearWord();
            return .{ .handled = true };
        },
        .escape => {
            if (!word) return .{ .handled = false };
            self.clearWord();
            return .{ .handled = true };
        },
        .up, .left, .down, .right => {
            if (!self.panelVisible()) return self.commitAndPass();
            const n = self.items.items.len;
            self.moveHighlight(if (k == .up or k == .left) (self.highlight + n - 1) % n else (self.highlight + 1) % n);
            return .{ .handled = true };
        },
        .page_up, .page_down => {
            if (!self.panelVisible()) return self.commitAndPass();
            const pages = self.pageCount();
            const p = if (k == .page_up) (self.page() + pages - 1) % pages else (self.page() + 1) % pages;
            self.moveHighlight(p * self.perPage());
            return .{ .handled = true };
        },
        .tab, .other => return self.commitAndPass(),
    }
}

/// Choose the `index`th candidate of the current page (a click or 1–9) and
/// commit it.
pub fn pick(self: *Composer, index: usize) !Outcome {
    self.committed.clearRetainingCapacity();
    if (!self.panelVisible() or index >= self.pageItems().len) return .{ .handled = false };
    self.moveHighlight(self.page() * self.perPage() + index);
    try self.commitHighlighted();
    return .{ .handled = true, .commit = self.committed.items };
}

/// Commit the word being typed, if any (focus leaving, the shell resetting).
/// Returns the text to insert.
pub fn flush(self: *Composer) ![]const u8 {
    self.committed.clearRetainingCapacity();
    if (self.composing()) try self.commitHighlighted();
    return self.committed.items;
}

/// Drop the word being typed without committing it.
pub fn reset(self: *Composer) void {
    self.clearWord();
}

/// Rebuild the candidate list, e.g. after the corrector reported new results.
pub fn refresh(self: *Composer) !void {
    if (!self.composing()) return;
    const keep: ?[]u8 = if (self.highlight > 0 and self.highlight < self.items.items.len)
        try self.gpa.dupe(u8, self.items.items[self.highlight])
    else
        null;
    defer if (keep) |k| self.gpa.free(k);

    var fresh = try self.ac().suggestWith(self.gpa, self.latin.items, .{ .dictionary = self.settings.suggestions });
    errdefer fresh.deinit();
    self.clearList();
    _ = self.extras.reset(.retain_capacity);
    self.avro = fresh;
    try self.items.appendSlice(self.gpa, fresh.items);
    self.avro_count = fresh.items.len;
    self.highlight = fresh.selected;

    if (self.settings.suggestions) try self.addExtras();

    // A refresh that only appended (corrections arriving) keeps the user's place.
    if (keep) |k| for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item, k)) {
        self.highlight = i;
        break;
    };
}

fn addExtras(self: *Composer) !void {
    const arena = self.extras.allocator();
    const plain = try self.ac().transliterate(self.gpa, arena, self.latin.items);
    if (plain.len == 0) return;

    const words = try self.user_words.prefix(arena, plain, user_word_limit);
    for (words) |w| if (!self.listed(w)) try self.items.append(self.gpa, w);

    // Corrections only when Avro found no dictionary word: its list is just
    // the plain transliteration.
    if (!self.settings.spelling_corrections or self.avro_count > 1) return;
    const corrector = self.corrector orelse return;
    if ((std.unicode.utf8CountCodepoints(plain) catch 0) < 2) return;
    if (self.user_words.contains(plain) or self.ac().contains(plain)) return;
    const fixes = corrector.get(plain) orelse return;
    var added: usize = 0;
    for (fixes) |f| {
        if (added == correction_limit) break;
        if (self.listed(f)) continue;
        try self.items.append(self.gpa, try arena.dupe(u8, f));
        added += 1;
    }
}

fn listed(self: Composer, word: []const u8) bool {
    for (self.items.items) |it| if (std.mem.eql(u8, it, word)) return true;
    return false;
}

fn moveHighlight(self: *Composer, to: usize) void {
    self.highlight = to;
    if (!self.settings.learn_choices or to >= self.avro_count) return;
    self.ac().select(self.gpa, self.latin.items, self.items.items[to]) catch return;
    self.selections_dirty = true;
}

fn commitHighlighted(self: *Composer) !void {
    try self.committed.appendSlice(self.gpa, self.preedit());
    self.clearWord();
    self.saveSelections();
}

fn commitAndPass(self: *Composer) !Outcome {
    if (self.composing()) try self.commitHighlighted();
    return .{ .handled = false, .commit = self.committed.items };
}

fn clearWord(self: *Composer) void {
    self.latin.clearRetainingCapacity();
    self.clearList();
    _ = self.extras.reset(.retain_capacity);
}

fn clearList(self: *Composer) void {
    if (self.avro) |*c| c.deinit();
    self.avro = null;
    self.items.clearRetainingCapacity();
    self.avro_count = 0;
    self.highlight = 0;
}

// —— Settings and user data ——

/// Apply and save new settings.
pub fn setSettings(self: *Composer, settings: Settings) !void {
    var s = settings;
    s.clamp();
    self.settings = s;
    const json = try s.stringify(self.gpa);
    defer self.gpa.free(json);
    self.store.save(Store.settings, json);
    self.remember(0, json);
    try self.refresh();
}

pub fn addUserWord(self: *Composer, word: []const u8) !bool {
    if (!try self.user_words.add(word)) return false;
    try self.saveUserWords();
    return true;
}

pub fn removeUserWord(self: *Composer, word: []const u8) !bool {
    if (!try self.user_words.remove(word)) return false;
    try self.saveUserWords();
    return true;
}

fn saveUserWords(self: *Composer) !void {
    const text = try self.user_words.serialize(self.gpa);
    defer self.gpa.free(text);
    self.store.save(Store.user_words, text);
    self.remember(2, text);
}

fn saveSelections(self: *Composer) void {
    if (!self.selections_dirty) return;
    const json = self.ac().exportSelections(self.gpa) catch return;
    defer self.gpa.free(json);
    self.store.save(Store.selections, json);
    self.remember(1, json);
    self.selections_dirty = false;
}

fn remember(self: *Composer, slot: usize, bytes: []const u8) void {
    const copy = self.gpa.dupe(u8, bytes) catch return;
    if (self.seen[slot]) |old| self.gpa.free(old);
    self.seen[slot] = copy;
}

/// Pick up user data changed by another process (the settings app, another
/// keyboard). Called when a word starts.
pub fn sync(self: *Composer) void {
    const names = [_][]const u8{ Store.settings, Store.selections, Store.user_words };
    for (names, 0..) |name, slot| {
        const bytes = self.store.load(self.gpa, name) orelse continue;
        if (self.seen[slot]) |old| if (std.mem.eql(u8, old, bytes)) {
            self.gpa.free(bytes);
            continue;
        };
        switch (slot) {
            0 => if (Settings.parse(self.gpa, bytes)) |s| {
                self.settings = s;
            } else |_| {},
            1 => {
                self.ac().clearSelections(self.gpa);
                self.ac().importSelections(self.gpa, bytes) catch {};
            },
            else => self.user_words.load(bytes) catch {},
        }
        if (self.seen[slot]) |old| self.gpa.free(old);
        self.seen[slot] = bytes;
    }
}

// ------------ TESTING ------------
const testing = std.testing;

test {
    _ = Settings;
    _ = Store;
    _ = FileStore;
    _ = UserWords;
}

const Harness = struct {
    memory: Store.Memory,
    c: Composer,

    fn init(h: *Harness) !void {
        h.memory = .init(testing.allocator);
        h.c = try Composer.init(testing.allocator, h.memory.store(), null);
    }
    fn deinit(h: *Harness) void {
        h.c.deinit();
        h.memory.deinit();
    }
    /// Type ASCII text one key at a time.
    fn typed(h: *Harness, text: []const u8) !void {
        for (text) |ch| _ = try h.c.key(.{ .char = ch }, .{});
    }
};

test "typing shows Avro's candidates, highlighted one inline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("bhalo");
    try testing.expect(h.c.panelVisible());
    try testing.expectEqualStrings("ভাল", h.c.preedit());
    try testing.expect(h.c.candidates().len > 5);
}

test "space commits the highlight and a space; idle space passes" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("ami");
    const o = try h.c.key(.space, .{});
    try testing.expect(o.handled);
    try testing.expectEqualStrings("আমি ", o.commit);
    try testing.expect(!h.c.composing());
    try testing.expect(!(try h.c.key(.space, .{})).handled);
}

test "enter commits the word only, or passes with newline_on_enter" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("ami");
    const o = try h.c.key(.enter, .{});
    try testing.expect(o.handled);
    try testing.expectEqualStrings("আমি", o.commit);
    try h.c.setSettings(.{ .newline_on_enter = true });
    try h.typed("ami");
    const n = try h.c.key(.enter, .{});
    try testing.expect(!n.handled);
    try testing.expectEqualStrings("আমি", n.commit);
}

test "escape drops, backspace edits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("amar");
    _ = try h.c.key(.backspace, .{});
    try testing.expectEqualStrings("আমা", h.c.preedit()[0..9]);
    try testing.expect((try h.c.key(.escape, .{})).handled);
    try testing.expect(!h.c.composing());
    try h.typed("k");
    _ = try h.c.key(.backspace, .{});
    try testing.expect(!h.c.composing());
    try testing.expect(!(try h.c.key(.backspace, .{})).handled);
}

test "arrows wrap, pages move, numbers pick" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.c.setSettings(.{ .candidates_per_page = 3, .learn_choices = false });
    try h.typed("bhalo");
    const n = h.c.candidates().len;
    _ = try h.c.key(.up, .{});
    try testing.expectEqual(n - 1, h.c.highlight);
    _ = try h.c.key(.down, .{});
    try testing.expectEqual(@as(usize, 0), h.c.highlight);
    _ = try h.c.key(.page_down, .{});
    try testing.expectEqual(@as(usize, 3), h.c.highlight);
    try testing.expectEqual(@as(usize, 1), h.c.page());
    try testing.expectEqual(@as(usize, 3), h.c.pageItems().len);
    const want = try testing.allocator.dupe(u8, h.c.pageItems()[1]);
    defer testing.allocator.free(want);
    const o = try h.c.key(.{ .char = '2' }, .{});
    try testing.expectEqualStrings(want, o.commit);
}

test "moving the highlight is learned and persisted" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("bhalo");
    _ = try h.c.key(.down, .{});
    _ = try h.c.key(.down, .{});
    _ = try h.c.key(.down, .{});
    const chosen = try testing.allocator.dupe(u8, h.c.preedit());
    defer testing.allocator.free(chosen);
    _ = try h.c.key(.space, .{});
    try h.typed("bhalo");
    try testing.expectEqualStrings(chosen, h.c.preedit());
    _ = try h.c.key(.escape, .{});

    // A second composer on the same store starts with the choice.
    var other = try Composer.init(testing.allocator, h.memory.store(), null);
    defer other.deinit();
    for ("bhalo") |ch| _ = try other.key(.{ .char = ch }, .{});
    try testing.expectEqualStrings(chosen, other.preedit());
}

test "phonetic mode: exact transliteration, no panel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.c.setSettings(.{ .suggestions = false });
    try h.typed("bhalO");
    try testing.expect(!h.c.panelVisible());
    try testing.expectEqualStrings("ভালো", h.c.preedit());
    try testing.expectEqualStrings("ভালো ", (try h.c.key(.space, .{})).commit);
}

test "digits: Bangla inside and outside words, or raw outside" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("12");
    try testing.expectEqualStrings("১২", (try h.c.flush()));
    try h.c.setSettings(.{ .bangla_digits = false });
    try testing.expect(!(try h.c.key(.{ .char = '7' }, .{})).handled);
}

test "shortcuts and other keys commit and pass" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.typed("ami");
    const o = try h.c.key(.{ .char = 'c' }, .{ .ctrl = true });
    try testing.expect(!o.handled);
    try testing.expectEqualStrings("আমি", o.commit);
    try h.typed("ami");
    try testing.expectEqualStrings("আমি", (try h.c.key(.tab, .{})).commit);
}

test "personal words follow Avro's list; settings sync from the store" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.c.addUserWord("বাংলাভাষী");
    try h.typed("bangla");
    var found = false;
    for (h.c.candidates()[h.c.avro_count..]) |w| found = found or std.mem.eql(u8, w, "বাংলাভাষী");
    try testing.expect(found);
    _ = try h.c.key(.escape, .{});

    // Another process turns suggestions off; the next word obeys.
    h.memory.store().save(Store.settings, "{\"suggestions\":false}");
    try h.typed("bangla");
    try testing.expect(!h.c.panelVisible());
}

const FakeCorrector = struct {
    ready: bool = false,
    fn corrector(self: *FakeCorrector) Corrector {
        return .{ .ctx = self, .vtable = &.{ .get = get } };
    }
    fn get(ctx: *anyopaque, _: []const u8) ?[]const []const u8 {
        const self: *FakeCorrector = @ptrCast(@alignCast(ctx));
        if (!self.ready) return null;
        return &.{ "বাংলা", "বাংলো" };
    }
};

test "corrections arrive later and are appended" {
    var memory = Store.Memory.init(testing.allocator);
    defer memory.deinit();
    var fake: FakeCorrector = .{};
    var c = try Composer.init(testing.allocator, memory.store(), fake.corrector());
    defer c.deinit();
    for ("bngl") |ch| _ = try c.key(.{ .char = ch }, .{});
    const before = c.candidates().len;
    fake.ready = true;
    try c.refresh();
    try testing.expect(c.candidates().len > before);
}
