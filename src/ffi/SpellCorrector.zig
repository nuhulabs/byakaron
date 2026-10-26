//! `Composer.Corrector` over Byakaron.db for native keyboards. A Byakaron.db lookup
//! can take long enough to stall a keystroke, so it runs on a worker thread:
//! `get` answers from the cache, otherwise queues the word (only the latest
//! waiting word is kept) and returns null; when a result lands, `on_ready` is
//! called — from the worker thread — and the shell asks the composer to
//! refresh on its own thread.

const SpellCorrector = @This();

const std = @import("std");
const Spell = @import("spell");
const Composer = @import("composer");

const cache_limit = 512;
const lookup_limit = 4;

gpa: std.mem.Allocator,
io: std.Io,
spell: *Spell,
on_ready: *const fn (userdata: ?*anyopaque) callconv(.c) void,
userdata: ?*anyopaque,

mutex: std.Io.Mutex = .init,
/// word → its corrections (all owned).
cache: std.StringHashMapUnmanaged([]const []const u8) = .empty,
/// Being looked up now / waiting for the worker (owned).
running: ?[]u8 = null,
waiting: ?[]u8 = null,
thread: ?std.Thread = null,
stopping: bool = false,
/// A copy of what `get` last returned (owned), so the worker can evict the
/// cache while the composer still reads it.
last: []const []const u8 = &.{},

pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    spell: *Spell,
    on_ready: *const fn (?*anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
) !*SpellCorrector {
    const self = try gpa.create(SpellCorrector);
    self.* = .{ .gpa = gpa, .io = io, .spell = spell, .on_ready = on_ready, .userdata = userdata };
    return self;
}

/// Waits for a running lookup, then frees everything.
pub fn destroy(self: *SpellCorrector) void {
    self.mutex.lockUncancelable(self.io);
    self.stopping = true;
    const thread = self.thread;
    self.thread = null;
    self.mutex.unlock(self.io);
    if (thread) |t| t.join();
    if (self.waiting) |w| self.gpa.free(w);
    self.clearCache();
    self.cache.deinit(self.gpa);
    freeList(self.gpa, self.last);
    self.gpa.destroy(self);
}

pub fn corrector(self: *SpellCorrector) Composer.Corrector {
    return .{ .ctx = self, .vtable = &.{ .get = get } };
}

fn clearCache(self: *SpellCorrector) void {
    var it = self.cache.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        freeList(self.gpa, e.value_ptr.*);
    }
    self.cache.clearRetainingCapacity();
}

fn copyList(gpa: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |w| gpa.free(w);
        gpa.free(out);
    }
    for (list) |w| {
        out[n] = try gpa.dupe(u8, w);
        n += 1;
    }
    return out;
}

fn freeList(gpa: std.mem.Allocator, list: []const []const u8) void {
    for (list) |w| gpa.free(w);
    gpa.free(list);
}

fn get(ctx: *anyopaque, word: []const u8) ?[]const []const u8 {
    const self: *SpellCorrector = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.cache.get(word)) |fixes| {
        const copy = copyList(self.gpa, fixes) catch return null;
        freeList(self.gpa, self.last);
        self.last = copy;
        return copy;
    }
    if (self.running) |r| if (std.mem.eql(u8, r, word)) return null;
    const copy = self.gpa.dupe(u8, word) catch return null;
    if (self.waiting) |w| self.gpa.free(w);
    self.waiting = copy;
    if (self.running == null) self.startWorker();
    return null;
}

/// With the mutex held: hand the waiting word to a (new) worker thread.
fn startWorker(self: *SpellCorrector) void {
    if (self.thread) |t| {
        // The previous worker has finished (running == null); reap it.
        self.mutex.unlock(self.io);
        t.join();
        self.mutex.lockUncancelable(self.io);
        self.thread = null;
    }
    self.running = self.waiting;
    self.waiting = null;
    self.thread = std.Thread.spawn(.{}, work, .{self}) catch blk: {
        if (self.running) |r| self.gpa.free(r);
        self.running = null;
        break :blk null;
    };
}

fn work(self: *SpellCorrector) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        const word = self.running orelse {
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);

        const fixes = self.lookup(word);

        self.mutex.lockUncancelable(self.io);
        if (self.cache.count() >= cache_limit) self.clearCache();
        if (fixes) |f| {
            self.cache.put(self.gpa, word, f) catch {
                self.gpa.free(word);
                freeList(self.gpa, f);
            };
        } else self.gpa.free(word);
        self.running = if (self.stopping) null else self.waiting;
        self.waiting = null;
        const more = self.running != null;
        self.mutex.unlock(self.io);

        if (fixes != null) self.on_ready(self.userdata);
        if (!more) return;
    }
}

/// Corrections for `word`, excluding the word itself (owned), or null on error.
fn lookup(self: *SpellCorrector, word: []const u8) ?[]const []const u8 {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const ranked = self.spell.suggestWord(arena.allocator(), word, "", "", "", lookup_limit) catch return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (ranked) |s| {
        if (std.mem.eql(u8, s.word, word)) continue;
        const copy = self.gpa.dupe(u8, s.word) catch break;
        out.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            break;
        };
    }
    return out.toOwnedSlice(self.gpa) catch null;
}
