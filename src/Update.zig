//! Byakaron updating itself on macOS, Windows and Linux: the part every app
//! shares. Each app fetches the release feed and installs what this picks;
//! which release that is, is decided here, once for all of them.
//!
//! Releases are on nuhulabs/Byakaron-Assets, tagged by the release workflow
//! (.github/workflows/release.yml) as
//!
//!   v27.0.0               production, the latest release
//!   v27.0.0-beta.N        beta        (prereleases, N counting from 0)
//!   v27.0.0-alpha.N       alpha
//!   v27.0.0-internal.N    internal
//!
//! A channel takes its own releases and those of every steadier channel:
//! beta also gets production releases, alpha gets beta and production, and
//! internal gets everything. So switching to a steadier channel never goes
//! back: the app waits on its version until the steadier channel passes it.
//!
//! The feed (`feed_url`) is GitHub's release list, trimmed to the fields
//! `pick` reads, which the release workflow writes to releases.json on
//! Byakaron-Assets after each release. The apps hand it to `pick` as it came.
//! It is a plain file, not GitHub's API, whose 60 requests an hour per
//! address run out fast when several computers share one.

const Update = @This();

const std = @import("std");

/// The version this build was made as (build.zig.zon's, which the release
/// workflow sets to the release's: "27.0.0-beta.3"; a local build says
/// "27.0.0-dev").
pub const build_version: []const u8 = @import("build_info").version;

/// The release feed: newest first, every channel's releases.
pub const feed_url = "https://raw.githubusercontent.com/nuhulabs/Byakaron-Assets/main/releases.json";

/// From the steadiest to the newest. The order is also the settings option
/// order (Settings.zig's `update_channel`), so `internal` stays last.
pub const Channel = enum(u8) {
    production,
    beta,
    alpha,
    internal,

    /// Whether this channel is offered `release`'s releases.
    pub fn takes(self: Channel, release: Channel) bool {
        return @backingInt(release) <= @backingInt(self);
    }
};

/// This build's channel; null for a build that is not a release (a local
/// "27.0.0-dev").
pub const build_channel: ?Channel = blk: {
    const v = Version.parse(build_version) catch break :blk null;
    break :blk v.channel();
};

/// The channel a build follows until someone picks one: its own, and internal
/// for a local build (only people working on Byakaron make those).
pub const default_channel: Channel = build_channel orelse .internal;

/// Whether the internal channel may be picked: only on an internal build (or
/// a local one). Everyone else sees production, beta and alpha.
pub const internal_offered = default_channel == .internal;

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// The SemVer prerelease, without its `-`: "beta.3", "dev", or "".
    pre: []const u8 = "",

    pub const ParseError = error{InvalidVersion};

    /// "27.0.0", "v27.0.0-beta.3", "27.0.0-dev+abc" (build metadata is
    /// dropped). `pre` points into `text`.
    pub fn parse(text: []const u8) ParseError!Version {
        var rest = text;
        if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];
        if (std.mem.indexOfScalar(u8, rest, '+')) |plus| rest = rest[0..plus];
        const dash = std.mem.indexOfScalar(u8, rest, '-');
        const core = rest[0 .. dash orelse rest.len];
        const pre = if (dash) |d| rest[d + 1 ..] else "";
        if (dash != null and pre.len == 0) return error.InvalidVersion;
        for (pre) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return error.InvalidVersion;

        var parts = std.mem.splitScalar(u8, core, '.');
        var nums: [3]u32 = undefined;
        for (&nums) |*n| {
            const part = parts.next() orelse return error.InvalidVersion;
            if (part.len == 0) return error.InvalidVersion;
            n.* = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
        }
        if (parts.next() != null) return error.InvalidVersion;
        return .{ .major = nums[0], .minor = nums[1], .patch = nums[2], .pre = pre };
    }

    /// The channel a release version belongs to: production with no
    /// prerelease, the track of "<track>.N". Null for anything else ("dev").
    pub fn channel(v: Version) ?Channel {
        if (v.pre.len == 0) return .production;
        const dot = std.mem.indexOfScalar(u8, v.pre, '.') orelse return null;
        const n = v.pre[dot + 1 ..];
        if (n.len == 0) return null;
        for (n) |c| if (!std.ascii.isDigit(c)) return null;
        const track = std.meta.stringToEnum(Channel, v.pre[0..dot]) orelse return null;
        return if (track == .production) null else track;
    }

    /// major.minor.patch alone.
    pub fn orderCore(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// SemVer 2.0 precedence.
    pub fn order(a: Version, b: Version) std.math.Order {
        const core = orderCore(a, b);
        if (core != .eq) return core;
        if (a.pre.len == 0 or b.pre.len == 0) return std.math.order(@intFromBool(a.pre.len == 0), @intFromBool(b.pre.len == 0));
        var ia = std.mem.splitScalar(u8, a.pre, '.');
        var ib = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const x = ia.next() orelse return if (ib.next() == null) .eq else .lt;
            const y = ib.next() orelse return .gt;
            const nx = std.fmt.parseInt(u64, x, 10) catch null;
            const ny = std.fmt.parseInt(u64, y, 10) catch null;
            const o: std.math.Order = if (nx != null and ny != null)
                std.math.order(nx.?, ny.?)
            else if (nx != null)
                .lt // numeric identifiers sort before alphanumeric ones
            else if (ny != null)
                .gt
            else
                std.mem.order(u8, x, y);
            if (o != .eq) return o;
        }
    }
};

/// What to update to.
pub const Pick = struct {
    /// "v27.1.0-beta.2"
    tag: []const u8,
    /// "27.1.0-beta.2"
    version: []const u8,
    channel: Channel,
    /// The asset's download URL.
    url: []const u8,
    /// Lowercase hex, from GitHub's digest of the asset; null when the feed
    /// has none (check the release's SHA256SUMS then).
    sha256: ?[]const u8,
    size: u64,
    /// The release's page.
    page: []const u8,
};

pub const PickError = error{ InvalidFeed, InvalidVersion } || std.mem.Allocator.Error;

/// GitHub's fields, the ones read here.
const FeedRelease = struct {
    tag_name: []const u8 = "",
    draft: bool = false,
    published_at: ?[]const u8 = null,
    html_url: []const u8 = "",
    assets: []const struct {
        name: []const u8 = "",
        browser_download_url: []const u8 = "",
        digest: ?[]const u8 = null,
        size: u64 = 0,
    } = &.{},
};

const Candidate = struct {
    release: *const FeedRelease,
    version: Version,
    channel: Channel,
    /// RFC 3339 in UTC, so it orders as text; "" when missing.
    published: []const u8,
};

/// The release `current` should update to on `channel`: the newest one the
/// channel takes that is newer than `current` and has `asset` ("Byakaron.dmg",
/// "Byakaron-Setup.exe", "byakaron_amd64.deb"). Null when there is none.
/// Everything returned is allocated in `arena`.
///
/// Newer means a later major.minor.patch; or, for the same, a production
/// release over a prerelease; or a later N on the same track. Two prerelease
/// tracks of the same version (27.0.0-internal.7 and 27.0.0-beta.2) do not
/// order by name: the one published later is newer.
pub fn pick(arena: std.mem.Allocator, feed_json: []const u8, current: []const u8, channel: Channel, asset: []const u8) PickError!?Pick {
    const mine = try Version.parse(current);
    const releases = std.json.parseFromSliceLeaky([]const FeedRelease, arena, feed_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFeed,
    };

    // When this version was released, if it is in the feed.
    var mine_published: ?[]const u8 = null;
    for (releases) |*r| {
        const v = Version.parse(r.tag_name) catch continue;
        if (v.order(mine) == .eq and std.mem.eql(u8, v.pre, mine.pre)) mine_published = r.published_at;
    }

    var best: ?Candidate = null;
    for (releases) |*r| {
        if (r.draft) continue;
        const v = Version.parse(r.tag_name) catch continue;
        const c = v.channel() orelse continue;
        if (!channel.takes(c)) continue;
        const candidate: Candidate = .{ .release = r, .version = v, .channel = c, .published = r.published_at orelse "" };
        if (!newerThanMine(candidate, mine, mine_published)) continue;
        if (findAsset(r, asset) == null) continue;
        if (best == null or better(candidate, best.?)) best = candidate;
    }

    const b = best orelse return null;
    const a = findAsset(b.release, asset).?;
    var sha256: ?[]const u8 = null;
    if (a.digest) |d| if (std.mem.startsWith(u8, d, "sha256:") and isHex64(d[7..])) {
        sha256 = try std.ascii.allocLowerString(arena, d[7..]);
    };
    const tag = b.release.tag_name;
    return .{
        .tag = tag,
        .version = if (tag[0] == 'v') tag[1..] else tag,
        .channel = b.channel,
        .url = a.browser_download_url,
        .sha256 = sha256,
        .size = a.size,
        .page = b.release.html_url,
    };
}

fn findAsset(r: *const FeedRelease, name: []const u8) ?@typeInfo(@TypeOf(r.assets)).pointer.child {
    for (r.assets) |a| if (std.mem.eql(u8, a.name, name) and a.browser_download_url.len > 0) return a;
    return null;
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn newerThanMine(c: Candidate, mine: Version, mine_published: ?[]const u8) bool {
    const core = c.version.orderCore(mine);
    if (core != .eq) return core == .gt;
    if (c.version.pre.len == 0) return mine.pre.len > 0;
    if (mine.pre.len == 0) return false;
    if (mine.channel() == c.channel) return c.version.order(mine) == .gt;
    if (mine_published) |p| if (c.published.len > 0) return std.mem.order(u8, c.published, p) == .gt;
    return c.version.order(mine) == .gt;
}

/// Whether `a` is a better update than `b`, both newer than this version.
fn better(a: Candidate, b: Candidate) bool {
    const core = a.version.orderCore(b.version);
    if (core != .eq) return core == .gt;
    const a_prod = a.version.pre.len == 0;
    const b_prod = b.version.pre.len == 0;
    if (a_prod != b_prod) return a_prod;
    if (a.channel == b.channel) return a.version.order(b.version) == .gt;
    return std.mem.order(u8, a.published, b.published) == .gt;
}

// ------------ TESTING ------------
const testing = std.testing;

test "versions and their channels" {
    const v = try Version.parse("v27.1.0-beta.3");
    try testing.expectEqual(@as(u32, 27), v.major);
    try testing.expectEqualStrings("beta.3", v.pre);
    try testing.expectEqual(Channel.beta, v.channel().?);
    try testing.expectEqual(Channel.production, (try Version.parse("27.0.0")).channel().?);
    try testing.expectEqual(Channel.internal, (try Version.parse("27.0.0-internal.0")).channel().?);
    try testing.expectEqual(Channel.alpha, (try Version.parse("27.0.0-alpha.12+abc")).channel().?);
    try testing.expectEqual(@as(?Channel, null), (try Version.parse("27.0.0-dev")).channel());
    try testing.expectEqual(@as(?Channel, null), (try Version.parse("27.0.0-beta")).channel());
    try testing.expectEqual(@as(?Channel, null), (try Version.parse("27.0.0-production.1")).channel());
    try testing.expectEqual(@as(?Channel, null), (try Version.parse("27.0.0-beta.x")).channel());
    for ([_][]const u8{ "", "v", "27", "27.0", "27.0.0.0", "27.0.0-", "27.a.0", "27.0.0-be ta.1" }) |bad| {
        try testing.expectError(error.InvalidVersion, Version.parse(bad));
    }
}

test "SemVer precedence" {
    const in_order = [_][]const u8{
        "1.0.0-alpha",   "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
        "1.0.0-beta.11", "1.0.0-rc.1",    "1.0.0",            "1.0.1",      "1.1.0",
        "2.0.0",
    };
    for (in_order[0 .. in_order.len - 1], in_order[1..]) |a, b| {
        const va = try Version.parse(a);
        const vb = try Version.parse(b);
        try testing.expectEqual(std.math.Order.lt, va.order(vb));
        try testing.expectEqual(std.math.Order.gt, vb.order(va));
        try testing.expectEqual(std.math.Order.eq, va.order(va));
    }
}

test "a channel takes its own releases and steadier ones" {
    try testing.expect(Channel.production.takes(.production));
    try testing.expect(!Channel.production.takes(.beta));
    try testing.expect(Channel.beta.takes(.production));
    try testing.expect(!Channel.beta.takes(.alpha));
    try testing.expect(Channel.alpha.takes(.beta));
    try testing.expect(!Channel.alpha.takes(.internal));
    try testing.expect(Channel.internal.takes(.alpha));
}

test "this build's channel" {
    const v = try Version.parse(build_version);
    try testing.expectEqual(v.channel(), build_channel);
    try testing.expectEqual(build_channel == null or build_channel == .internal, internal_offered);
}

const test_feed =
    \\[
    \\ {"tag_name":"v27.1.0-internal.4","draft":false,"prerelease":true,"published_at":"2026-11-10T09:00:00Z",
    \\  "html_url":"https://github.com/nuhulabs/Byakaron-Assets/releases/tag/v27.1.0-internal.4",
    \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/i4/Byakaron.dmg","size":5,"digest":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}]},
    \\ {"tag_name":"v27.1.0-beta.0","draft":false,"prerelease":true,"published_at":"2026-11-08T09:00:00Z","html_url":"b0",
    \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/b0/Byakaron.dmg","size":4},
    \\            {"name":"Byakaron-Setup.exe","browser_download_url":"https://x/b0/Byakaron-Setup.exe","size":6}]},
    \\ {"tag_name":"v27.1.0-alpha.1","draft":true,"published_at":null,"html_url":"draft",
    \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/a1/Byakaron.dmg","size":4}]},
    \\ {"tag_name":"v27.1.0-internal.3","draft":false,"published_at":"2026-11-05T09:00:00Z","html_url":"i3",
    \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/i3/Byakaron.dmg","size":4}]},
    \\ {"tag_name":"v27.0.0","draft":false,"prerelease":false,"published_at":"2026-11-01T09:00:00Z","html_url":"p",
    \\  "assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/p/Byakaron.dmg","size":3,"digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
    \\            {"name":"Byakaron-Setup.exe","browser_download_url":"https://x/p/Byakaron-Setup.exe","size":3}]},
    \\ {"tag_name":"not-a-version","assets":[]},
    \\ {"tag_name":"v26.9.0-dev","published_at":"2026-01-01T00:00:00Z","assets":[{"name":"Byakaron.dmg","browser_download_url":"https://x/dev","size":1}]}
    \\]
;

test "pick: the newest release the channel takes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prod = (try pick(a, test_feed, "26.5.0", .production, "Byakaron.dmg")).?;
    try testing.expectEqualStrings("v27.0.0", prod.tag);
    try testing.expectEqualStrings("27.0.0", prod.version);
    try testing.expectEqual(Channel.production, prod.channel);
    try testing.expectEqualStrings("https://x/p/Byakaron.dmg", prod.url);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", prod.sha256.?);
    try testing.expectEqual(@as(u64, 3), prod.size);

    const beta = (try pick(a, test_feed, "27.0.0", .beta, "Byakaron.dmg")).?;
    try testing.expectEqualStrings("v27.1.0-beta.0", beta.tag);
    try testing.expectEqual(@as(?[]const u8, null), beta.sha256);

    // Alpha takes beta; the alpha release is a draft.
    try testing.expectEqualStrings("v27.1.0-beta.0", (try pick(a, test_feed, "27.0.0", .alpha, "Byakaron.dmg")).?.tag);

    // Internal: internal.4 was published after beta.0, and its digest is lowercased.
    const internal = (try pick(a, test_feed, "27.0.0", .internal, "Byakaron.dmg")).?;
    try testing.expectEqualStrings("v27.1.0-internal.4", internal.tag);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", internal.sha256.?);

    // Only releases with the asset: Windows has no internal.4.
    try testing.expectEqualStrings("v27.1.0-beta.0", (try pick(a, test_feed, "27.0.0", .internal, "Byakaron-Setup.exe")).?.tag);
    try testing.expectEqual(@as(?Pick, null), try pick(a, test_feed, "27.0.0", .internal, "nothing.zip"));
}

test "pick: never back, and tracks of one version by date" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Up to date.
    try testing.expectEqual(@as(?Pick, null), try pick(a, test_feed, "27.0.0", .production, "Byakaron.dmg"));
    // A beta user who switched to production waits for a production release past 27.1.0-beta.0.
    try testing.expectEqual(@as(?Pick, null), try pick(a, test_feed, "27.1.0-beta.0", .production, "Byakaron.dmg"));
    // From internal.3 on internal: internal.4 (same track, higher N).
    try testing.expectEqualStrings("v27.1.0-internal.4", (try pick(a, test_feed, "27.1.0-internal.3", .internal, "Byakaron.dmg")).?.tag);
    // From internal.3 on beta: beta.0 was published after internal.3.
    try testing.expectEqualStrings("v27.1.0-beta.0", (try pick(a, test_feed, "27.1.0-internal.3", .beta, "Byakaron.dmg")).?.tag);
    // From internal.4 on beta: beta.0 is older, though "beta" < "internal" either way.
    try testing.expectEqual(@as(?Pick, null), try pick(a, test_feed, "27.1.0-internal.4", .beta, "Byakaron.dmg"));
    // From beta.0 on internal: internal.4 is later.
    try testing.expectEqualStrings("v27.1.0-internal.4", (try pick(a, test_feed, "v27.1.0-beta.0", .internal, "Byakaron.dmg")).?.tag);
    // A local build updates like any other version.
    try testing.expectEqualStrings("v27.0.0", (try pick(a, test_feed, "27.0.0-dev", .production, "Byakaron.dmg")).?.tag);
}

test "pick: bad input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidFeed, pick(a, "{\"message\":\"API rate limit exceeded\"}", "27.0.0", .beta, "Byakaron.dmg"));
    try testing.expectError(error.InvalidFeed, pick(a, "[", "27.0.0", .beta, "Byakaron.dmg"));
    try testing.expectError(error.InvalidVersion, pick(a, "[]", "nope", .beta, "Byakaron.dmg"));
    try testing.expectEqual(@as(?Pick, null), try pick(a, "[]", "27.0.0", .beta, "Byakaron.dmg"));
}
