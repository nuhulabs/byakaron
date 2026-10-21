//! Build-time tool: unpack Debian packages into a cross-compilation sysroot.
//!
//!   linux_sysroot <out_dir> <pkg.deb>...
//!
//! Each `.deb` is an `ar` archive whose last member is `data.tar.zst` (or
//! `.xz` in older releases). Its contents are extracted under
//! `<out_dir>`, with absolute symlinks (`libglib-2.0.so -> /lib/<triple>/…`)
//! rewritten relative to the sysroot so they resolve inside it.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <out_dir> <pkg.deb>...\n", .{args[0]});
        return error.InvalidArguments;
    }

    var out = try Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer out.close(io);
    for (args[2..]) |deb| {
        extractDeb(gpa, io, out, deb) catch |err| {
            std.debug.print("error: {s}: {t}\n", .{ deb, err });
            return err;
        };
    }
}

fn extractDeb(gpa: std.mem.Allocator, io: Io, out: Io.Dir, path: []const u8) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const r = &file_reader.interface;

    if (!std.mem.eql(u8, try r.takeArray(8), "!<arch>\n")) return error.NotADeb;
    while (true) {
        // ar member header: name[16] mtime[12] uid[6] gid[6] mode[8] size[10] magic[2]
        const header = r.takeArray(60) catch |err| switch (err) {
            error.EndOfStream => return error.NoDataMember,
            else => |e| return e,
        };
        const name = std.mem.trimEnd(u8, header[0..16], " /");
        const size = try std.fmt.parseInt(u64, std.mem.trim(u8, header[48..58], " "), 10);

        if (std.mem.eql(u8, name, "data.tar.zst")) {
            const zstd = std.compress.zstd;
            const window = try gpa.alloc(u8, zstd.default_window_len + zstd.block_size_max);
            defer gpa.free(window);
            var dec: zstd.Decompress = .init(r, window, .{});
            return extractTar(io, out, &dec.reader);
        }
        if (std.mem.eql(u8, name, "data.tar.xz")) {
            var dec = try std.compress.xz.Decompress.init(r, gpa, try gpa.alloc(u8, 1 << 16));
            defer dec.deinit();
            return extractTar(io, out, &dec.reader);
        }
        if (std.mem.startsWith(u8, name, "data.tar")) return error.UnsupportedCompression;
        try r.discardAll64(size + size % 2);
    }
}

fn extractTar(io: Io, out: Io.Dir, reader: *Io.Reader) !void {
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var rel_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var contents_buf: [16 * 1024]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });

    while (try it.next()) |entry| {
        // Entries are `./usr/...`; anything escaping the sysroot is skipped.
        const name = std.mem.trimStart(u8, std.mem.trimStart(u8, entry.name, "."), "/");
        if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) continue;

        switch (entry.kind) {
            .directory => try out.createDirPath(io, name),
            .file => {
                if (std.fs.path.dirname(name)) |d| try out.createDirPath(io, d);
                var f = try out.createFile(io, name, .{});
                defer f.close(io);
                var w = f.writer(io, &contents_buf);
                try it.streamRemaining(entry, &w.interface);
                try w.interface.flush();
            },
            .sym_link => {
                const dir = std.fs.path.dirname(name) orelse "";
                const target = if (std.fs.path.isAbsolute(entry.link_name))
                    try sysrootRelative(&rel_buf, dir, entry.link_name)
                else
                    entry.link_name;
                if (dir.len > 0) try out.createDirPath(io, dir);
                out.deleteFile(io, name) catch {};
                try out.symLink(io, target, name, .{});
            },
        }
    }
}

/// `/lib/x/libfoo.so.0` seen from `usr/lib/x` → `../../../lib/x/libfoo.so.0`.
fn sysrootRelative(buf: []u8, from_dir: []const u8, abs_target: []const u8) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    var parts = std.mem.tokenizeScalar(u8, from_dir, '/');
    while (parts.next()) |_| try w.writeAll("../");
    try w.writeAll(abs_target[1..]);
    return w.buffered();
}
