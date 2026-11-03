//! Streaming bzip2 decompression as a `std.Io.Reader`, backed by libbz2
//! (allyourcodebase/bzip2). Handles concatenated streams.

const Bz2Reader = @This();

const std = @import("std");
const Io = std.Io;

input: *Io.Reader,
strm: BzStream = .{},
/// libbz2 keeps a pointer back to `strm`, so the decoder is initialized on the
/// first read, once this struct has reached its final address.
started: bool = false,
done: bool = false,
interface: Io.Reader,

pub fn init(input: *Io.Reader, buffer: []u8) Bz2Reader {
    return .{
        .input = input,
        .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
    };
}

pub fn deinit(self: *Bz2Reader) void {
    if (self.started) _ = BZ2_bzDecompressEnd(&self.strm);
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const self: *Bz2Reader = @alignCast(@fieldParentPtr("interface", r));
    if (self.done) return error.EndOfStream;
    if (!self.started) {
        if (BZ2_bzDecompressInit(&self.strm, 0, 0) != BZ_OK) return error.ReadFailed;
        self.started = true;
    }
    const dest = limit.slice(try w.writableSliceGreedy(1));

    while (true) {
        if (self.input.bufferedLen() == 0) {
            self.input.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    self.done = true;
                    return error.EndOfStream;
                },
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const in = self.input.buffered();
        self.strm.next_in = @constCast(in.ptr);
        self.strm.avail_in = @intCast(@min(in.len, std.math.maxInt(c_uint)));
        self.strm.next_out = dest.ptr;
        self.strm.avail_out = @intCast(@min(dest.len, std.math.maxInt(c_uint)));

        const rc = BZ2_bzDecompress(&self.strm);
        self.input.toss(in.len - self.strm.avail_in);
        const produced = dest.len - self.strm.avail_out;

        switch (rc) {
            BZ_OK => {},
            // Another stream may follow (e.g. pbzip2 output); restart the decoder.
            BZ_STREAM_END => {
                _ = BZ2_bzDecompressEnd(&self.strm);
                self.strm = .{};
                if (BZ2_bzDecompressInit(&self.strm, 0, 0) != BZ_OK) return error.ReadFailed;
            },
            else => return error.ReadFailed,
        }
        if (produced > 0) {
            w.advance(produced);
            return produced;
        }
    }
}

// ── libbz2 (bzlib.h) ────────────────────────────────────────────────────────

const BZ_OK = 0;
const BZ_STREAM_END = 4;

const BzStream = extern struct {
    next_in: [*]u8 = undefined,
    avail_in: c_uint = 0,
    total_in_lo32: c_uint = 0,
    total_in_hi32: c_uint = 0,
    next_out: [*]u8 = undefined,
    avail_out: c_uint = 0,
    total_out_lo32: c_uint = 0,
    total_out_hi32: c_uint = 0,
    state: ?*anyopaque = null,
    bzalloc: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) ?*anyopaque = null,
    bzfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    @"opaque": ?*anyopaque = null,
};

extern fn BZ2_bzDecompressInit(strm: *BzStream, verbosity: c_int, small: c_int) c_int;
extern fn BZ2_bzDecompress(strm: *BzStream) c_int;
extern fn BZ2_bzDecompressEnd(strm: *BzStream) c_int;
