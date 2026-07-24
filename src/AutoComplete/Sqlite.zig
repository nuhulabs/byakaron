//! SQLite-backed AutoComplete via `zx.Db.Sqlite`.

const Sqlite = @This();

const std = @import("std");
const zx = @import("zx");
const AutoComplete = @import("autocomplete");

allocator: std.mem.Allocator,
db: zx.Db,
engine: AutoComplete,

pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Sqlite {
    const self = try allocator.create(Sqlite);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .db = try zx.Db.Sqlite.open(allocator, io, path, .{
            .readonly = true,
            .create = false,
            .readwrite = false,
            .max_pool_size = 1,
        }),
        .engine = undefined,
    };
    errdefer self.db.deinit();

    self.engine = AutoComplete.init(&vtable, self);
    return self;
}

pub fn deinit(self: *Sqlite) void {
    self.db.deinit();
    self.allocator.destroy(self);
}

pub fn autoComplete(self: *Sqlite) *AutoComplete {
    return &self.engine;
}

const vtable = AutoComplete.VTable{
    .prefix_lookup = prefixLookup,
    .contains = containsWord,
};

fn asSelf(ctx: *anyopaque) *Sqlite {
    return @ptrCast(@alignCast(ctx));
}

fn containsWord(ctx: *anyopaque, word: []const u8) bool {
    const self = asSelf(ctx);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const row = self.db.row(arena.allocator(), struct { word: []const u8 },
        \\SELECT word FROM dictionary WHERE word = ?1 LIMIT 1
    , .{word}) catch return false;
    return row != null;
}

fn prefixLookup(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    limit: i64,
) ![]const AutoComplete.LexiconEntry {
    const self = asSelf(ctx);
    const like = try std.fmt.allocPrint(allocator, "{s}%", .{prefix});
    return try self.db.rows(allocator, AutoComplete.LexiconEntry,
        \\SELECT word, frequency FROM dictionary
        \\WHERE word LIKE ?1
        \\ORDER BY length(word) ASC, frequency DESC
        \\LIMIT ?2
    , .{ like, limit });
}
