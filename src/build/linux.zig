//! Build-time helper for the Linux port, run by the `*-linux` build steps.
//!
//!   linux package-deb <repo-root> <ime> <app> <Byakaron.db> <out-dir> [fcitx.so]
//!   linux install <repo-root> <ime> <app> [Byakaron.db] [--fcitx <fcitx.so>]
//!   linux uninstall
//!   linux deps [--test]
//!   linux dev <repo-root> <ime>
//!   linux ime-test <repo-root> <ime> <ime-test-bin>
//!   linux assert-glibc <binary>
//!   linux ci <repo-root> [install-prefix]
//!   linux tested <ime-test-bin> [expected-version]
//!   linux install-matrix <ime-test-bin> <deb-or-dir> [--tool=<linux-exe>] [image...]
//!   linux wayland-e2e <repo-root> <engine-bin>
//!   linux package-flatpak <repo-root> <app> <out-dir>
//!
//! The binaries are built by the build graph before any of these run; nothing
//! here calls `zig build`. Replaces apps/linux/scripts/{package_deb,install,
//! uninstall,setup_deps,compat,build_zig,smoke,dev_run,test_ime,ci,
//! test_installed,test_install_matrix,gnome_wayland_test,package_flatpak,
//! wayland_probe,wayland_type,release,site_installers}.sh.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Child = std.process.Child;

const app_id = "dev.nuhu.labs.Byakaron";

const Tool = struct {
    arena: Allocator,
    io: Io,
    /// The environment every child process runs with; `ci` / `ime-test` extend it.
    env: *Environ.Map,
};

pub fn main(init: std.process.Init) u8 {
    return dispatch(init) catch |err| {
        if (err != error.Failed) std.debug.print("error: {t}\n", .{err});
        return 1;
    };
}

fn dispatch(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var t: Tool = .{ .arena = arena, .io = init.io, .env = init.environ_map };

    const command = if (args.len > 1) args[1] else "";
    const rest = if (args.len > 1) args[2..] else args[1..];
    const eql = std.mem.eql;

    if (eql(u8, command, "package-deb") and (rest.len == 5 or rest.len == 6)) {
        try packageDeb(&t, rest);
    } else if (eql(u8, command, "install") and rest.len >= 3) {
        try install(&t, rest);
    } else if (eql(u8, command, "uninstall") and rest.len == 0) {
        try uninstall(&t);
    } else if (eql(u8, command, "deps") and rest.len <= 1) {
        try deps(&t, rest);
    } else if (eql(u8, command, "dev") and rest.len == 2) {
        try dev(&t, rest[0], rest[1]);
    } else if (eql(u8, command, "ime-test") and rest.len == 3) {
        return imeTest(&t, rest[0], rest[1], rest[2]);
    } else if (eql(u8, command, "assert-glibc") and rest.len == 1) {
        try assertGlibc(&t, rest[0]);
    } else if (eql(u8, command, "ci") and (rest.len == 1 or rest.len == 2)) {
        return ci(&t, rest[0], if (rest.len == 2) rest[1] else null);
    } else if (eql(u8, command, "tested") and (rest.len == 1 or rest.len == 2)) {
        return tested(&t, rest);
    } else if (eql(u8, command, "install-matrix") and rest.len >= 2) {
        return installMatrix(&t, rest);
    } else if (eql(u8, command, "wayland-e2e") and rest.len == 2) {
        return waylandE2e(&t, rest[0], rest[1]);
    } else if (eql(u8, command, "package-flatpak") and rest.len == 3) {
        try packageFlatpak(&t, rest);
    } else {
        std.debug.print(
            \\usage: {s} package-deb <repo-root> <ime> <app> <Byakaron.db> <out-dir> [fcitx.so]
            \\       {s} install <repo-root> <ime> <app> [Byakaron.db] [--fcitx <fcitx.so>]
            \\       {s} uninstall
            \\       {s} deps [--test]
            \\       {s} dev <repo-root> <ime>
            \\       {s} ime-test <repo-root> <ime> <ime-test-bin>
            \\       {s} assert-glibc <binary>
            \\       {s} ci <repo-root> [install-prefix]
            \\       {s} tested <ime-test-bin> [expected-version]
            \\       {s} install-matrix <ime-test-bin> <deb-or-dir> [--tool=<linux-exe>] [image...]
            \\       {s} wayland-e2e <repo-root> <engine-bin>
            \\       {s} package-flatpak <repo-root> <app> <out-dir>
            \\
        , .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0] });
        return error.InvalidArguments;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// package-deb
// ---------------------------------------------------------------------------

fn packageDeb(t: *Tool, a: []const []const u8) !void {
    const repo = a[0];
    const ime = a[1];
    const app = a[2];
    const spell_db = a[3];
    const out_dir = a[4];
    const fcitx_so: ?[]const u8 = if (a.len == 6) a[5] else null;

    if (isRoot()) {
        return fail("do not run this as root: zig-out would become root-owned, and the next\n       non-root build would fail. Run: zig build package-linux", .{});
    }

    const version = try readVersion(t, repo);
    const arch = try debArch(t);
    const res = try join(t, &.{ repo, "apps/linux/Resources" });
    const fcitx_res = try join(t, &.{ repo, "apps/linux/Fcitx5" });

    try assertGlibc(t, ime);
    try assertGlibc(t, app);

    const name = try std.fmt.allocPrint(t.arena, "byakaron_{s}_{s}", .{ version, arch });
    const stage = try join(t, &.{ repo, "apps/linux/build/deb", name });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(t.io, stage) catch {};
    try cwd.createDirPath(t.io, try join(t, &.{ stage, "DEBIAN" }));

    // Ship stripped binaries so the download is small (the built ones carry
    // debug_info).
    const staged_ime = try join(t, &.{ stage, "usr/libexec/byakaron-ibus" });
    try installFile(t, "755", ime, staged_ime);
    strip(t, staged_ime);
    const staged_app = try join(t, &.{ stage, "usr/bin/byakaron" });
    try installFile(t, "755", app, staged_app);
    strip(t, staged_app);

    try installFile(t, "644", try join(t, &.{ res, "byakaron.svg" }), try join(t, &.{ stage, "usr/share/icons/hicolor/scalable/apps/byakaron.svg" }));
    try installFile(t, "644", try join(t, &.{ res, app_id ++ ".gschema.xml" }), try join(t, &.{ stage, "usr/share/glib-2.0/schemas/" ++ app_id ++ ".gschema.xml" }));
    try installFile(t, "644", try join(t, &.{ res, app_id ++ ".metainfo.xml" }), try join(t, &.{ stage, "usr/share/metainfo/" ++ app_id ++ ".metainfo.xml" }));
    try render(t, try join(t, &.{ res, "byakaron-app.desktop.in" }), try join(t, &.{ stage, "usr/share/applications/" ++ app_id ++ ".desktop" }), &.{
        .{ "@BYK_APP_EXEC@", "/usr/bin/byakaron" },
    });
    std.debug.print(">>> Packaged the GTK app (Spelling / Layout / Setup)\n", .{});

    if (!exists(t.io, spell_db)) return fail("{s} is missing; run: zig build db", .{spell_db});
    try installFile(t, "644", spell_db, try join(t, &.{ stage, "usr/share/byakaron/Byakaron.db" }));
    std.debug.print(">>> Packaged Byakaron.db\n", .{});

    try render(t, try join(t, &.{ res, "byakaron.xml.in" }), try join(t, &.{ stage, "usr/share/ibus/component/byakaron.xml" }), &.{
        .{ "@BYK_EXEC@", "/usr/libexec/byakaron-ibus" },
        .{ "@BYK_ICON@", "/usr/share/icons/hicolor/scalable/apps/byakaron.svg" },
        .{ "@BYK_SETUP@", "/usr/bin/byakaron --page=setup" },
    });

    if (fcitx_so) |so| {
        try assertGlibc(t, so);
        const libdir = try fcitxLibdir(t);
        const staged_so = try join(t, &.{ stage, std.mem.trimStart(u8, libdir, "/"), "fcitx5/byakaron.so" });
        try installFile(t, "755", so, staged_so);
        strip(t, staged_so);
        try installFile(t, "644", try join(t, &.{ fcitx_res, "byakaron-addon.conf" }), try join(t, &.{ stage, "usr/share/fcitx5/addon/byakaron.conf" }));
        try installFile(t, "644", try join(t, &.{ fcitx_res, "byakaron.conf" }), try join(t, &.{ stage, "usr/share/fcitx5/inputmethod/byakaron.conf" }));
        std.debug.print(">>> Packaged the Fcitx5 addon\n", .{});
    }

    const installed_kb = blk: {
        const du = capture(t, &.{ "du", "-sk", try join(t, &.{ stage, "usr" }) }) orelse break :blk "0";
        const end = std.mem.indexOfAny(u8, du, " \t") orelse du.len;
        break :blk du[0..end];
    };

    // Control metadata.
    const control = try std.fmt.allocPrint(t.arena,
        \\Package: byakaron
        \\Version: {s}
        \\Architecture: {s}
        \\Maintainer: Byakaron contributors <byakaron@example.com>
        \\Installed-Size: {s}
        \\Depends: libc6 (>= 2.31), ibus (>= 1.5), libibus-1.0-5, libglib2.0-0t64 | libglib2.0-0, libgtk-3-0t64 | libgtk-3-0, libglib2.0-bin
        \\Recommends: ibus-gtk3 | ibus-gtk, ibus-gtk4
        \\Suggests: fcitx5
        \\Replaces: byakaron-app, byakaron-data
        \\Conflicts: byakaron-app, byakaron-data
        \\Provides: byakaron-app, byakaron-data
        \\Section: utils
        \\Priority: optional
        \\Homepage: https://nuhulabs.com/byakaron
        \\Description: Bangla phonetic input method (IBus engine)
        \\ Type Bangla phonetically from a latin keyboard. Registers as a
        \\ first-class input source in GNOME Settings -> Keyboard -> Input Sources and
        \\ switches with Super+Space, powered by the shared Byakaron Zig engine.
        \\ .
        \\ Includes a GTK3 companion app (Spelling, Layout, Setup) that runs on
        \\ Ubuntu 20.04, 22.04, and 24.04, and the spell-check dictionary.
        \\
    , .{ version, arch, installed_kb });
    try writeFile(t, try join(t, &.{ stage, "DEBIAN/control" }), control, "644");
    try writeFile(t, try join(t, &.{ stage, "DEBIAN/postinst" }), postinst, "755");
    try writeFile(t, try join(t, &.{ stage, "DEBIAN/postrm" }), postrm, "755");

    // Build the .deb (root:root ownership without needing sudo).
    const out = try std.fmt.allocPrint(t.arena, "{s}/{s}.deb", .{ out_dir, name });
    cwd.deleteFile(t.io, out) catch {};
    try run(t, &.{ "dpkg-deb", "--root-owner-group", "--build", stage, out });

    std.debug.print(
        \\
        \\=== Built: {s} ===
        \\
        \\Share this one file. It is a complete install (keyboard, app, spell-check)
        \\on Ubuntu 20.04, 22.04, and 24.04. Do not use 'dpkg -i': apt is what
        \\installs ibus and GTK.
        \\
        \\    sudo apt install ./{s}.deb
        \\
        \\Then they MUST add it (installing the package is not enough):
        \\    Settings -> Keyboard -> Input Sources -> +
        \\    Choose Bangla, then Byakaron (Bangla Phonetic) -> Add
        \\    Super+Space to switch
        \\    Or open the Byakaron app from Activities -> Setup
        \\
        \\If they previously installed an older byakaron / byakaron-data .deb:
        \\    sudo apt remove byakaron byakaron-app byakaron-data
        \\then install the new file. Remove with:
        \\    sudo apt remove byakaron
        \\
    , .{ out, name });
}

// apt runs these as root. The ibus daemon and its cache belong to each
// logged-in desktop session, so refresh those buses as the session user.
// runuser is in util-linux (essential); sudo is not a package dependency.
const postinst =
    \\#!/bin/bash
    \\set -e
    \\
    \\as_session_user() {
    \\    local uid_dir="$1"
    \\    shift
    \\    local uid user
    \\    uid="$(basename "$uid_dir")"
    \\    user="$(getent passwd "$uid" | cut -d: -f1)"
    \\    [ -n "$user" ] || return 0
    \\    runuser -u "$user" -- env \
    \\        DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
    \\        "$@" >/dev/null 2>&1 || true
    \\}
    \\
    \\refresh_ibus() {
    \\    for uid_dir in /run/user/*; do
    \\        [ -S "$uid_dir/bus" ] || continue
    \\        as_session_user "$uid_dir" ibus write-cache
    \\        as_session_user "$uid_dir" ibus restart
    \\    done
    \\}
    \\
    \\if [ "$1" = "configure" ]; then
    \\    glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
    \\    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    \\    gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true
    \\    refresh_ibus
    \\    # $2 is the version being upgraded from, empty on a first install. An
    \\    # upgrade keeps the input source the user already added, so the steps
    \\    # would only be noise. The curl installer prints them itself and sets
    \\    # BYAKARON_INSTALLER so they do not appear twice.
    \\    if [ -n "$2" ]; then
    \\        echo "Byakaron updated from $2. Your input source stays as it is."
    \\    elif [ -z "${BYAKARON_INSTALLER:-}" ]; then
    \\        echo ""
    \\        echo "Byakaron installed. The package only registers the engine — add it:"
    \\        if command -v gnome-control-center >/dev/null; then
    \\            echo "  1. Settings -> Keyboard -> Input Sources -> '+'"
    \\            echo "  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add"
    \\            echo "  3. Switch with Super+Space"
    \\            echo "  If Byakaron is missing from the Bangla list, log out and back in."
    \\        else
    \\            echo "  1. As yourself: im-config -n ibus   (then log out and back in)"
    \\            echo "  2. ibus-setup -> Input Method -> Add -> Bangla -> Byakaron"
    \\            echo "  3. Switch with Super+Space"
    \\        fi
    \\        echo "  Or open the Byakaron app -> Setup, which walks through this."
    \\    fi
    \\fi
    \\
    \\exit 0
    \\
;

const postrm =
    \\#!/bin/bash
    \\set -e
    \\
    \\as_session_user() {
    \\    local uid_dir="$1"
    \\    shift
    \\    local uid user
    \\    uid="$(basename "$uid_dir")"
    \\    user="$(getent passwd "$uid" | cut -d: -f1)"
    \\    [ -n "$user" ] || return 0
    \\    runuser -u "$user" -- env \
    \\        DBUS_SESSION_BUS_ADDRESS="unix:path=$uid_dir/bus" \
    \\        "$@" >/dev/null 2>&1 || true
    \\}
    \\
    \\if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    \\    glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
    \\    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    \\    gtk-update-icon-cache -qtf /usr/share/icons/hicolor >/dev/null 2>&1 || true
    \\    for uid_dir in /run/user/*; do
    \\        [ -S "$uid_dir/bus" ] || continue
    \\        as_session_user "$uid_dir" ibus write-cache
    \\        as_session_user "$uid_dir" ibus restart
    \\    done
    \\fi
    \\
    \\exit 0
    \\
;

// ---------------------------------------------------------------------------
// install / uninstall
// ---------------------------------------------------------------------------

const libexecdir = "/usr/libexec";
const bindir = "/usr/bin";
const xmldir = "/usr/share/ibus/component";
const icondir = "/usr/share/icons/hicolor/scalable/apps";
const desktopdir = "/usr/share/applications";
const metainfo_dir = "/usr/share/metainfo";
const datadir = "/usr/share/byakaron";
const schemadir = "/usr/share/glib-2.0/schemas";

/// A system install is the only kind ibus-daemon sees: it builds its registry
/// from /usr/share/ibus/component alone (IBUS_COMPONENT_PATH is not honoured by
/// ibus 1.5.x). `run-linux` registers from the build tree instead, without root.
fn install(t: *Tool, a: []const []const u8) !void {
    const repo = a[0];
    const ime = a[1];
    const app = a[2];
    var spell_db: ?[]const u8 = null;
    var fcitx_so: ?[]const u8 = null;
    var i: usize = 3;
    while (i < a.len) : (i += 1) {
        if (std.mem.eql(u8, a[i], "--fcitx") and i + 1 < a.len) {
            i += 1;
            fcitx_so = a[i];
        } else {
            spell_db = a[i];
        }
    }

    if (!isRoot()) return fail("this needs root: run sudo -E zig build install-linux\n       (a first run as your user builds everything, so root does not write a root-owned cache)", .{});
    const res = try join(t, &.{ repo, "apps/linux/Resources" });

    try assertGlibc(t, ime);
    try assertGlibc(t, app);

    try run(t, &.{ "install", "-d", libexecdir, bindir, xmldir, icondir, desktopdir, metainfo_dir, datadir, schemadir });

    // Install the binary before the XML: the XML points at its final path and
    // ibus will try to exec exactly that.
    try installFile(t, "755", ime, libexecdir ++ "/byakaron-ibus");
    std.debug.print(">>> Installed: {s}/byakaron-ibus\n", .{libexecdir});

    try installFile(t, "644", try join(t, &.{ res, "byakaron.svg" }), icondir ++ "/byakaron.svg");
    std.debug.print(">>> Installed: {s}/byakaron.svg\n", .{icondir});

    try installFile(t, "644", try join(t, &.{ res, app_id ++ ".gschema.xml" }), schemadir ++ "/" ++ app_id ++ ".gschema.xml");
    try run(t, &.{ "glib-compile-schemas", schemadir });
    std.debug.print(">>> Installed: {s}/{s}.gschema.xml\n", .{ schemadir, app_id });

    // The app goes in /usr/bin, not /usr/libexec: it is something the user
    // launches, unlike the engine, which only ibus-daemon ever execs.
    try installFile(t, "755", app, bindir ++ "/byakaron");
    std.debug.print(">>> Installed: {s}/byakaron\n", .{bindir});
    try render(t, try join(t, &.{ res, "byakaron-app.desktop.in" }), desktopdir ++ "/" ++ app_id ++ ".desktop", &.{
        .{ "@BYK_APP_EXEC@", bindir ++ "/byakaron" },
    });
    try installFile(t, "644", try join(t, &.{ res, app_id ++ ".metainfo.xml" }), metainfo_dir ++ "/" ++ app_id ++ ".metainfo.xml");
    std.debug.print(">>> Installed: {s}/{s}.desktop\n", .{ desktopdir, app_id });
    std.debug.print(">>> Installed: {s}/{s}.metainfo.xml\n", .{ metainfo_dir, app_id });

    if (spell_db) |db| {
        if (exists(t.io, db)) {
            try installFile(t, "644", db, datadir ++ "/Byakaron.db");
            std.debug.print(">>> Installed: {s}/Byakaron.db\n", .{datadir});
        } else {
            std.debug.print("note: {s} missing; spell-check will be unavailable (zig build db)\n", .{db});
        }
    } else {
        std.debug.print("note: no Byakaron.db given; spell-check will be unavailable (zig build db)\n", .{});
    }

    try render(t, try join(t, &.{ res, "byakaron.xml.in" }), xmldir ++ "/byakaron.xml", &.{
        .{ "@BYK_EXEC@", libexecdir ++ "/byakaron-ibus" },
        .{ "@BYK_ICON@", icondir ++ "/byakaron.svg" },
        .{ "@BYK_SETUP@", bindir ++ "/byakaron --page=setup" },
    });
    std.debug.print(">>> Installed: {s}/byakaron.xml\n", .{xmldir});

    // Fcitx5 is optional: same composer, different framework. Only installed
    // when the build graph produced it this run.
    if (fcitx_so) |so| {
        try assertGlibc(t, so);
        const fcitx_res = try join(t, &.{ repo, "apps/linux/Fcitx5" });
        const fdir = try fcitxLibdir(t);
        try run(t, &.{ "install", "-d", try join(t, &.{ fdir, "fcitx5" }), "/usr/share/fcitx5/addon", "/usr/share/fcitx5/inputmethod" });
        try installFile(t, "755", so, try join(t, &.{ fdir, "fcitx5/byakaron.so" }));
        try installFile(t, "644", try join(t, &.{ fcitx_res, "byakaron-addon.conf" }), "/usr/share/fcitx5/addon/byakaron.conf");
        try installFile(t, "644", try join(t, &.{ fcitx_res, "byakaron.conf" }), "/usr/share/fcitx5/inputmethod/byakaron.conf");
        std.debug.print(">>> Installed: {s}/fcitx5/byakaron.so\n", .{fdir});
        std.debug.print("    (Fcitx5 users add Byakaron in the Fcitx5 config tool; this does not switch the session IM)\n", .{});
    }

    // Without these the app has no icon and does not show up in the activities
    // search until the desktop rescans on its own schedule.
    _ = ok(t, &.{ "update-desktop-database", desktopdir });
    _ = ok(t, &.{ "gtk-update-icon-cache", "-qtf", "/usr/share/icons/hicolor" });

    // ibus caches the registry, so a new component stays invisible until the
    // daemon re-reads it. Restarting drops the active engine, so put it back.
    const user = desktopUser(t);
    if (ok(t, &.{ "pgrep", "-x", "ibus-daemon" })) {
        const prev = try asUserOut(t, user, &.{ "ibus", "engine" });
        const keep = prev.len > 0 and std.mem.indexOf(u8, prev, "No engine") == null;
        std.debug.print(">>> Refreshing the ibus registry...\n", .{});
        _ = try asUserOk(t, user, &.{ "ibus", "write-cache" });
        _ = try asUserOk(t, user, &.{ "ibus", "restart" });
        try t.io.sleep(.fromSeconds(2), .awake);
        if (keep) {
            _ = try asUserOk(t, user, &.{ "ibus", "engine", prev });
            std.debug.print(">>> Restored input engine: {s}\n", .{prev});
        }
    } else {
        std.debug.print("note: ibus-daemon is not running; the engine appears once it starts\n", .{});
    }

    const engines = try asUserOut(t, user, &.{ "ibus", "list-engine" });
    if (std.mem.indexOf(u8, engines, "byakaron") != null) {
        std.debug.print("\n=== Installed. 'byakaron' is in the ibus registry. ===\n", .{});
    } else {
        std.debug.print("\n!!! Installed, but 'byakaron' is not listed by 'ibus list-engine' yet.\n" ++
            "    Log out and back in, then run 'ibus list-engine | grep byakaron'.\n", .{});
    }
    std.debug.print(
        \\
        \\To start typing Bangla:
        \\  1. Settings -> Keyboard -> Input Sources -> '+'
        \\  2. Choose Bangla, then Byakaron (Bangla Phonetic) -> Add
        \\  3. Switch with Super+Space
        \\  (the first dialog is a language list; searching Byakaron there finds nothing)
        \\
        \\The 'Byakaron' app is installed too: it walks through the steps above,
        \\types Bangla without switching input source, and checks spelling.
        \\
    , .{});
}

fn uninstall(t: *Tool) !void {
    if (!isRoot()) return fail("this needs root: run sudo zig build uninstall-linux", .{});

    const files = [_][]const u8{
        "/usr/libexec/byakaron-ibus",
        "/usr/bin/byakaron",
        "/usr/share/ibus/component/byakaron.xml",
        "/usr/share/applications/byakaron.desktop",
        "/usr/share/applications/" ++ app_id ++ ".desktop",
        "/usr/share/metainfo/" ++ app_id ++ ".metainfo.xml",
        "/usr/share/icons/hicolor/scalable/apps/byakaron.svg",
        "/usr/share/byakaron/Byakaron.db",
        "/usr/share/glib-2.0/schemas/" ++ app_id ++ ".gschema.xml",
        "/usr/share/fcitx5/addon/byakaron.conf",
        "/usr/share/fcitx5/inputmethod/byakaron.conf",
    };

    const user = desktopUser(t);
    const daemon = ok(t, &.{ "pgrep", "-x", "ibus-daemon" });

    // Switch away first: pulling the binary out from under the active engine
    // would leave the session unable to type.
    if (daemon) {
        const cur = try asUserOut(t, user, &.{ "ibus", "engine" });
        if (std.mem.eql(u8, cur, "byakaron")) {
            std.debug.print(">>> byakaron is active; switching to xkb:us::eng first\n", .{});
            _ = try asUserOk(t, user, &.{ "ibus", "engine", "xkb:us::eng" });
        }
    }

    _ = ok(t, &.{ "pkill", "-f", "[b]yakaron-ibus" });
    // The app holds no session state, but leaving it running against a deleted
    // binary and a deleted Byakaron.db is not worth the confusion.
    _ = ok(t, &.{ "pkill", "-x", "byakaron" });

    const cwd = Io.Dir.cwd();
    for (files) |f| {
        if (!exists(t.io, f)) continue;
        cwd.deleteFile(t.io, f) catch |err| return fail("cannot remove {s}: {t}", .{ f, err });
        std.debug.print(">>> Removed: {s}\n", .{f});
    }
    // Multiarch addon path varies; remove whichever copy install left.
    cwd.deleteFile(t.io, "/usr/lib/fcitx5/byakaron.so") catch {};
    if (cwd.openDir(t.io, "/usr/lib", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(t.io);
        var it = dir.iterate();
        while (it.next(t.io) catch null) |entry| {
            const so = try join(t, &.{ "/usr/lib", entry.name, "fcitx5/byakaron.so" });
            cwd.deleteFile(t.io, so) catch {};
        }
    } else |_| {}
    cwd.deleteDir(t.io, "/usr/share/byakaron") catch {};
    _ = ok(t, &.{ "glib-compile-schemas", schemadir });
    _ = ok(t, &.{ "update-desktop-database", desktopdir });
    _ = ok(t, &.{ "gtk-update-icon-cache", "-qtf", "/usr/share/icons/hicolor" });

    if (daemon) {
        std.debug.print(">>> Refreshing the ibus registry...\n", .{});
        _ = try asUserOk(t, user, &.{ "ibus", "write-cache" });
        _ = try asUserOk(t, user, &.{ "ibus", "restart" });
        try t.io.sleep(.fromSeconds(2), .awake);
    }
    std.debug.print("=== Uninstalled ===\n", .{});
}

/// The user whose desktop session owns the ibus daemon: whoever ran sudo.
fn desktopUser(t: *Tool) ?[]const u8 {
    const u = t.env.get("SUDO_USER") orelse return null;
    if (u.len == 0 or std.mem.eql(u8, u, "root")) return null;
    return u;
}

/// `argv` as the desktop user (with their session bus), or as ourselves.
fn asUserArgv(t: *Tool, user: ?[]const u8, argv: []const []const u8) ![]const []const u8 {
    const u = user orelse return argv;
    const uid = capture(t, &.{ "id", "-u", u }) orelse return argv;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(t.arena, &.{
        "sudo",                                                                                          "-u", u, "-H", "env",
        try std.fmt.allocPrint(t.arena, "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{s}/bus", .{uid}),
    });
    try list.appendSlice(t.arena, argv);
    return list.items;
}

fn asUserOk(t: *Tool, user: ?[]const u8, argv: []const []const u8) !bool {
    return ok(t, try asUserArgv(t, user, argv));
}

fn asUserOut(t: *Tool, user: ?[]const u8, argv: []const []const u8) ![]const u8 {
    return capture(t, try asUserArgv(t, user, argv)) orelse "";
}

// ---------------------------------------------------------------------------
// deps
// ---------------------------------------------------------------------------

/// The default set is what running needs (IBus, the GTK3 IM module,
/// glib-compile-schemas). `--test` adds a C compiler and the -dev packages the
/// system-toolchain test helpers (smoke aside, the wayland probes) build with.
/// Building itself needs no -dev packages: `zig build linux` downloads a
/// pinned Ubuntu sysroot.
fn deps(t: *Tool, a: []const []const u8) !void {
    const with_test = a.len == 1 and std.mem.eql(u8, a[0], "--test");
    if (a.len == 1 and !with_test) return error.InvalidArguments;
    if (!isRoot()) return fail("run me with sudo: sudo zig build linux-deps", .{});

    var pkgs: std.ArrayList([]const u8) = .empty;
    try pkgs.appendSlice(t.arena, &.{ "ibus", "ibus-gtk3", "libglib2.0-bin", "gettext" });
    if (with_test) try pkgs.appendSlice(t.arena, &.{ "build-essential", "pkg-config", "libibus-1.0-dev", "libglib2.0-dev", "libgtk-3-dev" });

    std.debug.print(">>> apt-get update\n", .{});
    try run(t, &.{ "apt-get", "update", "-qq" });

    std.debug.print(">>> installing:", .{});
    for (pkgs.items) |p| std.debug.print(" {s}", .{p});
    std.debug.print("\n", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(t.arena, &.{ "apt-get", "install", "-y" });
    try argv.appendSlice(t.arena, pkgs.items);
    try run(t, argv.items);

    if (!with_test) {
        std.debug.print("\n=== dependencies ready ===\n", .{});
        return;
    }

    // GTK4 is only needed for the IME typing tests (wayland_type.c), not the app.
    if (ok(t, &.{ "apt-cache", "show", "libgtk-4-dev" })) {
        std.debug.print(">>> installing optional GTK4 (IME tests): libgtk-4-dev ibus-gtk4\n", .{});
        _ = ok(t, &.{ "apt-get", "install", "-y", "libgtk-4-dev", "ibus-gtk4" });
    }

    std.debug.print("\n>>> verifying pkg-config modules\n", .{});
    var missing = false;
    for ([_][]const u8{ "ibus-1.0", "glib-2.0", "gtk+-3.0" }) |m| {
        if (capture(t, &.{ "pkg-config", "--modversion", m })) |v| {
            std.debug.print("    {s: <14} {s}\n", .{ m, v });
        } else {
            std.debug.print("    {s: <14} MISSING\n", .{m});
            missing = true;
        }
    }
    if (missing) return fail("some modules are still missing; see above", .{});
    std.debug.print("\n=== dependencies ready ===\n", .{});
}

// ---------------------------------------------------------------------------
// dev / ime-test
// ---------------------------------------------------------------------------

/// Register the engine with the *running* ibus-daemon straight from the build
/// tree, without installing anything into /usr. The registration lives only as
/// long as this process, so Ctrl-C removes it again. Replaces this process.
fn dev(t: *Tool, repo: []const u8, ime: []const u8) !void {
    try useBuiltSpellDb(t, repo);
    const xml = try writeComponentXml(t, repo, ime);
    std.debug.print(">>> Component XML: {s}\n", .{xml});

    if (!ok(t, &.{ "pgrep", "-x", "ibus-daemon" })) {
        return fail("ibus-daemon is not running; start it with 'ibus-daemon -drx'", .{});
    }

    const schemas = try join(t, &.{ repo, "zig-out/share/glib-2.0/schemas" });
    if (exists(t.io, try join(t, &.{ schemas, "gschemas.compiled" }))) try t.env.put("GSETTINGS_SCHEMA_DIR", schemas);

    std.debug.print(">>> Registering with ibus-daemon (Ctrl-C to unregister and exit)\n\n", .{});
    const err = std.process.replace(t.io, .{ .argv = &.{ ime, "--xml", xml }, .environ_map = t.env });
    return err;
}

/// Point the engine at the built Byakaron.db unless the caller chose one.
fn useBuiltSpellDb(t: *Tool, repo: []const u8) !void {
    if (t.env.get("BYAKARON_SPELL_DB") != null) return;
    const db = try join(t, &.{ repo, "zig-out/db/Byakaron.db" });
    if (exists(t.io, db)) try t.env.put("BYAKARON_SPELL_DB", db);
}

/// Fill in the IBus component template with the build tree's absolute path.
fn writeComponentXml(t: *Tool, repo: []const u8, ime: []const u8) ![]const u8 {
    const xml = try join(t, &.{ repo, "apps/linux/build/byakaron.xml" });
    try render(t, try join(t, &.{ repo, "apps/linux/Resources/byakaron.xml.in" }), xml, &.{
        .{ "@BYK_EXEC@", ime },
        .{ "@BYK_ICON@", "input-keyboard" },
        .{ "@BYK_SETUP@", "" },
    });
    return xml;
}

/// A throwaway engine process registered with the running ibus-daemon.
/// Focusing the test's input context makes the daemon adopt its engine as the
/// session's global one, so killing the engine afterwards would leave the
/// desktop with "No global engine" and no way to type. Remember what was
/// active and put it back.
const Engine = struct {
    child: Child,
    prev: []const u8,

    fn start(t: *Tool, ime: []const u8, xml: []const u8) !Engine {
        var prev = capture(t, &.{ "ibus", "engine" }) orelse "";
        if (std.mem.indexOf(u8, prev, "No engine") != null) prev = "";

        std.debug.print(">>> Starting engine...\n", .{});
        var child = try std.process.spawn(t.io, .{ .argv = &.{ ime, "--xml", xml }, .stdin = .ignore, .environ_map = t.env });
        // Give the daemon a moment to accept the component registration.
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            if (!alive(t, &child)) {
                _ = child.wait(t.io) catch {};
                return fail("engine exited early", .{});
            }
            try t.io.sleep(.fromMilliseconds(200), .awake);
        }
        return .{ .child = child, .prev = prev };
    }

    fn stop(e: *Engine, t: *Tool) void {
        if (alive(t, &e.child)) {
            if (e.child.id) |pid| _ = ok(t, &.{ "kill", pidStr(t, pid) });
            _ = e.child.wait(t.io) catch {};
            std.debug.print(">>> Engine stopped\n", .{});
        }
        if (e.prev.len > 0) {
            const cur = capture(t, &.{ "ibus", "engine" }) orelse "";
            if (!std.mem.eql(u8, cur, e.prev)) {
                _ = ok(t, &.{ "ibus", "engine", e.prev });
                std.debug.print(">>> Restored input engine: {s}\n", .{e.prev});
            }
        }
    }
};

/// Run the IME integration test against a throwaway engine. The desktop's own
/// input source is never touched. Returns the test's exit status.
fn imeTest(t: *Tool, repo: []const u8, ime: []const u8, test_bin: []const u8) !u8 {
    try useBuiltSpellDb(t, repo);

    // Default settings, not the desktop's: the user's old GSettings choices
    // (Bangla digits off, say) would otherwise be migrated into the throwaway
    // settings.json and change what the engine types.
    try t.env.put("GSETTINGS_BACKEND", "memory");

    // A throwaway data directory (settings.json, selections.json,
    // user-words.txt): the test writes the personal dictionary while the engine
    // runs, the way the app does, and never touches the user's real files.
    // Avro's remembered choices start empty each run.
    const data_dir = try join(t, &.{ repo, "apps/linux/build/ime-test-data" });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(t.io, data_dir) catch {};
    try cwd.createDirPath(t.io, data_dir);
    // Not empty at start: reading an existing file at engine start is what once
    // crashed (a stat() struct mismatch under Zig's libc headers).
    try cwd.writeFile(t.io, .{ .sub_path = try join(t, &.{ data_dir, "user-words.txt" }), .data = "আমায়\n" });
    try t.env.put("BYAKARON_DATA_DIR", data_dir);

    if (!ok(t, &.{ "pgrep", "-x", "ibus-daemon" })) {
        return fail("ibus-daemon is not running; start it with 'ibus-daemon -drx'", .{});
    }

    const xml = try writeComponentXml(t, repo, ime);
    var engine = try Engine.start(t, ime, xml);
    defer engine.stop(t);

    std.debug.print(">>> Running integration test...\n\n", .{});
    const code = try runExit(t, &.{test_bin});
    if (code == 77) std.debug.print("note: test skipped; the engine was not reachable\n", .{});
    return code;
}

// ---------------------------------------------------------------------------
// assert-glibc
// ---------------------------------------------------------------------------

/// Fail if `bin` needs a GLIBC symbol newer than 2.31 (Ubuntu 20.04). Zig can
/// emit that ABI while still linking this machine's libibus and libglib, so one
/// engine binary runs on 20.04, 22.04, and 24.04.
fn assertGlibc(t: *Tool, bin: []const u8) !void {
    const r = std.process.run(t.arena, t.io, .{
        .argv = &.{ "objdump", "-T", bin },
        .stdout_limit = .limited(256 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .environ_map = t.env,
    }) catch return; // no objdump: nothing to check with
    if (!r.term.success()) return;

    const prefix = "GLIBC_";
    var max: ?[2]u32 = null;
    var it = std.mem.tokenizeAny(u8, r.stdout, " \t\r\n()");
    while (it.next()) |tok| {
        const at = std.mem.indexOf(u8, tok, prefix) orelse continue;
        const ver = tok[at + prefix.len ..];
        const dot = std.mem.indexOfScalar(u8, ver, '.') orelse continue;
        var end = dot + 1;
        while (end < ver.len and std.ascii.isDigit(ver[end])) end += 1;
        const major = std.fmt.parseInt(u32, ver[0..dot], 10) catch continue;
        const minor = std.fmt.parseInt(u32, ver[dot + 1 .. end], 10) catch continue;
        if (max == null or major > max.?[0] or (major == max.?[0] and minor > max.?[1])) max = .{ major, minor };
    }
    const v = max orelse return;
    if (v[0] > 2 or (v[0] == 2 and v[1] > 31)) {
        return fail("{s} needs GLIBC_{d}.{d}; Ubuntu 20.04 only has 2.31\n       build for glibc 2.31 (the default Linux target; do not pass -Dlinux-system-libs with a newer -Dtarget)", .{ bin, v[0], v[1] });
    }
    std.debug.print(">>> {s} highest GLIBC is {d}.{d} (Ubuntu 20.04-safe)\n", .{ bin, v[0], v[1] });
}

// ---------------------------------------------------------------------------
// ci
// ---------------------------------------------------------------------------

/// What GitHub Actions runs on ubuntu-latest, and what you can run here to see
/// the same failures before pushing: everything in the old scripts/ci.sh after
/// the binaries exist. The IME integration test needs an ibus-daemon: in CI (no
/// session) and on a desktop with Xvfb installed this starts a private Xvfb +
/// dbus + ibus; otherwise it falls back to the session daemon.
fn ci(t: *Tool, repo: []const u8, prefix_arg: ?[]const u8) !u8 {
    const prefix = prefix_arg orelse try join(t, &.{ repo, "zig-out" });
    const bin = try join(t, &.{ prefix, "bin" });
    const ime = try join(t, &.{ bin, "byakaron-ibus" });
    const app = try join(t, &.{ bin, "byakaron" });
    const ime_test = try join(t, &.{ bin, "byakaron-ime-test" });
    const linux_dir = try join(t, &.{ repo, "apps/linux" });

    // The engine and the smoke test read the Byakaron.db when present; both skip
    // those assertions when it is absent (it is 364 MB and not needed here).
    if (t.env.get("BYAKARON_SPELL_DB") == null) {
        const db = try join(t, &.{ prefix, "db/Byakaron.db" });
        if (exists(t.io, db)) try t.env.put("BYAKARON_SPELL_DB", db);
    }

    std.debug.print("\n=== glibc 2.31 compatibility ===\n", .{});
    try assertGlibc(t, ime);
    try assertGlibc(t, app);

    std.debug.print("\n=== GTK3 app --help / --version (no display needed) ===\n", .{});
    try checkAppCli(t, app, linux_dir);

    const smoke = try join(t, &.{ bin, "byakaron-smoke" });
    std.debug.print("\n=== smoke (C ABI + Core glue) ===\n", .{});
    if (exists(t.io, smoke)) {
        if (t.env.get("BYAKARON_SPELL_DB") == null) std.debug.print("note: Byakaron.db missing; spell-check assertions will be skipped\n", .{});
        try run(t, &.{smoke});
    } else {
        std.debug.print("note: {s} not built; skipped\n", .{smoke});
    }

    var session: Session = .{};
    defer session.stop(t);

    std.debug.print("\n", .{});
    // A private daemon whenever one can be started, even on a desktop: the
    // session daemon follows real focus, so switching windows while this runs
    // resets the test's input context mid-word (seen as "bangla" -> লা) and
    // leaves the desktop on our throwaway engine. BYAKARON_SESSION_IBUS=1 opts
    // back into the session daemon.
    const in_ci = envIs(t, "CI", "true") or envIs(t, "BYAKARON_CI", "1");
    const can_headless = haveCmd(t, "Xvfb") and haveCmd(t, "ibus-daemon") and haveCmd(t, "dbus-launch");
    if (in_ci or (!envIs(t, "BYAKARON_SESSION_IBUS", "1") and can_headless)) {
        try session.start(t);
        std.debug.print("=== IME integration test (headless ibus-daemon) ===\n", .{});
        const code = try imeTest(t, repo, ime, ime_test);
        if (code != 0) return fail("IME integration test failed ({d})", .{code});
    } else if (ok(t, &.{ "pgrep", "-x", "ibus-daemon" })) {
        std.debug.print("=== IME integration test (session ibus-daemon) ===\n", .{});
        const code = try imeTest(t, repo, ime, ime_test);
        if (code != 0) return fail("IME integration test failed ({d})", .{code});
    } else {
        std.debug.print("=== IME integration test skipped ===\n" ++
            "note: no ibus-daemon, and Xvfb/dbus-launch are not installed to start\n" ++
            "      a throwaway one (apt install xvfb ibus dbus-x11).\n", .{});
    }

    std.debug.print("\n=== wayland / display-path probe ===\n", .{});
    try waylandProbe(t, bin, linux_dir);

    std.debug.print("\n=== Fcitx5 addon ===\n", .{});
    const fcitx_so = try join(t, &.{ prefix, "lib/fcitx5/byakaron.so" });
    if (exists(t.io, fcitx_so)) {
        const syms = capture(t, &.{ "nm", "-D", fcitx_so }) orelse "";
        if (std.mem.indexOf(u8, syms, "fcitx_addon_factory_instance") == null) {
            return fail("{s} does not export fcitx_addon_factory_instance", .{fcitx_so});
        }
        try assertGlibc(t, fcitx_so);
        std.debug.print(">>> {s} exports fcitx_addon_factory_instance\n", .{fcitx_so});
    } else {
        std.debug.print("skipped (zig build linux-fcitx5 was not run; needs libfcitx5core-dev)\n", .{});
    }

    std.debug.print("\n=== GtkEntry typing (IBus IM module) ===\n", .{});
    // Needs a running ibus-daemon, which the IME block above either found or started.
    const type_bin = try join(t, &.{ bin, "byakaron-wayland-type" });
    if (!ok(t, &.{ "pgrep", "-x", "ibus-daemon" })) {
        std.debug.print("note: no ibus-daemon; GtkEntry typing skipped\n", .{});
    } else if (!exists(t.io, type_bin)) {
        std.debug.print("note: {s} not built (needs libgtk-4-dev); skipped\n", .{type_bin});
    } else {
        try waylandType(t, repo, ime, type_bin);
    }

    std.debug.print("\n=== icon loads in GNOME's image loader ===\n", .{});
    try checkIcon(t, try join(t, &.{ linux_dir, "Resources/byakaron.svg" }));

    std.debug.print("\n=== website installer: CPU / system detection ===\n", .{});
    const web_test = try join(t, &.{ linux_dir, "tests/web_install_test.sh" });
    if (exists(t.io, web_test)) try run(t, &.{ "bash", web_test }) else std.debug.print("skipped (no tests/web_install_test.sh)\n", .{});

    std.debug.print("\n=== AppStream metainfo ===\n", .{});
    if (!haveCmd(t, "appstreamcli")) return fail("appstreamcli is required (apt install appstream)", .{});
    try run(t, &.{ "appstreamcli", "validate", "--no-net", try join(t, &.{ linux_dir, "Resources/" ++ app_id ++ ".metainfo.xml" }) });

    std.debug.print("\n=== linux-ci finished ===\n", .{});
    return 0;
}

fn checkAppCli(t: *Tool, app: []const u8, linux_dir: []const u8) !void {
    const help = std.process.run(t.arena, t.io, .{ .argv = &.{ app, "--help" }, .environ_map = t.env }) catch |err| {
        return fail("cannot run {s} --help: {t}", .{ app, err });
    };
    const text = try std.mem.concat(t.arena, u8, &.{ help.stdout, help.stderr });
    for ([_][]const u8{ "--version", "--page" }) |flag| {
        if (std.mem.indexOf(u8, text, flag) == null) {
            std.debug.print("{s}\n", .{text});
            return fail("byakaron --help does not mention {s}", .{flag});
        }
    }

    const header = try Io.Dir.cwd().readFileAlloc(t.io, try join(t, &.{ linux_dir, "App/app.h" }), t.arena, .limited(1024 * 1024));
    const define = "#define BYK_APP_VERSION \"";
    const at = std.mem.indexOf(u8, header, define) orelse return fail("BYK_APP_VERSION not found in App/app.h", .{});
    const ver_start = at + define.len;
    const ver_end = std.mem.indexOfScalarPos(u8, header, ver_start, '"') orelse return fail("malformed BYK_APP_VERSION", .{});
    const expected = try std.fmt.allocPrint(t.arena, "byakaron {s}", .{header[ver_start..ver_end]});

    const got = capture(t, &.{ app, "--version" }) orelse return fail("{s} --version failed", .{app});
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), expected)) {
            std.debug.print(">>> {s}\n", .{got});
            return;
        }
    }
    return fail("expected '{s}', got: {s}", .{ expected, got });
}

/// GNOME draws app icons with gdk-pixbuf, which sniffs only the start of a file
/// to decide it is SVG. 0.1.8 shipped a long header comment before <svg>, and
/// the app grid showed a blank tile. Check the tag is near the top and that it
/// loads.
fn checkIcon(t: *Tool, icon: []const u8) !void {
    const svg = try Io.Dir.cwd().readFileAlloc(t.io, icon, t.arena, .limited(16 * 1024 * 1024));
    const at = std.mem.indexOf(u8, svg, "<svg");
    if (at == null or at.? > 64) {
        return fail("<svg> starts at byte {?d} of {s}; keep it at the top", .{ at, icon });
    }
    try run(t, &.{
        "python3", "-c",
        \\import sys, gi
        \\gi.require_version('GdkPixbuf', '2.0')
        \\from gi.repository import GdkPixbuf
        \\for size in (16, 32, 64, 256):
        \\    p = GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], size, size)
        \\    assert p.get_width() == size, (size, p.get_width())
        \\print(">>> byakaron.svg loads at 16/32/64/256 px")
        ,
        icon,
    });
}

/// Report which display backend a GTK4 client would use to talk to IBus and,
/// when mutter is installed, open a nested Wayland compositor to prove the
/// text-input-v3 stack comes up. The engine has no X11 or Wayland calls
/// (Keyboard/engine.c only speaks IBusEngine); a coupled engine fails CI.
/// Missing mutter (CI) is a skip, not a failure.
fn waylandProbe(t: *Tool, bin: []const u8, linux_dir: []const u8) !void {
    for ([_][]const u8{ "XDG_SESSION_TYPE", "WAYLAND_DISPLAY", "DISPLAY", "GDK_BACKEND", "GTK_IM_MODULE", "QT_IM_MODULE", "XMODIFIERS" }) |k| {
        std.debug.print("{s}={s}\n", .{ k, t.env.get(k) orelse "unset" });
    }

    var coupled = false;
    const keyboard = try join(t, &.{ linux_dir, "Keyboard" });
    if (Io.Dir.cwd().openDir(t.io, keyboard, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(t.io);
        var it = dir.iterate();
        while (it.next(t.io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".c") and !std.mem.endsWith(u8, entry.name, ".h")) continue;
            const src = Io.Dir.cwd().readFileAlloc(t.io, try join(t, &.{ keyboard, entry.name }), t.arena, .limited(16 * 1024 * 1024)) catch continue;
            for ([_][]const u8{ "#include <X11", "#include <gdk/gdkx", "#include <gdk/gdkwayland", "#include <wayland-client" }) |inc| {
                if (std.mem.indexOf(u8, src, inc) != null) coupled = true;
            }
        }
    } else |_| {}
    if (coupled) return fail("Keyboard/ includes a display-server header; the engine must stay IBus D-Bus only", .{});
    std.debug.print("Keyboard/ has no X11 or Wayland headers: IBus D-Bus only\n", .{});

    const probe = try join(t, &.{ bin, "byakaron-wayland-probe" });
    if (!exists(t.io, probe)) {
        std.debug.print("note: {s} not built (needs libgtk-4-dev); probe skipped\n", .{probe});
        return;
    }

    std.debug.print("\n--- probe on the current session ---\n", .{});
    // Unset GDK_BACKEND so GTK picks whatever this session actually is.
    _ = try runWith(t, &.{probe}, &.{}, &.{"GDK_BACKEND"});

    if (!haveCmd(t, "mutter")) {
        std.debug.print("\nnote: mutter not installed; nested Wayland compositor skipped\n" ++
            "      (this is expected in CI; GNOME sessions have it)\n", .{});
        return;
    }

    std.debug.print("\n--- nested Wayland compositor (mutter --headless) ---\n", .{});
    const wl_name = "byakaron-wl-probe";
    var mutter = (try startMutter(t, wl_name)) orelse {
        std.debug.print("note: mutter did not create WAYLAND_DISPLAY={s}; engine path is still display-agnostic\n", .{wl_name});
        return;
    };
    defer mutter.kill(t.io);
    // Force the Wayland backend so a lingering DISPLAY=:1 cannot pull us back to X11.
    const code = try runWith(t, &.{probe}, &.{
        .{ "WAYLAND_DISPLAY", wl_name }, .{ "GDK_BACKEND", "wayland" }, .{ "GTK_A11Y", "none" },
    }, &.{"DISPLAY"});
    if (code != 0) {
        std.debug.print("note: GTK4 did not start against the nested compositor\n", .{});
    } else {
        std.debug.print("\nGTK4's IM context id 'wayland' speaks zwp_text_input_v3 to the compositor; mutter\n" ++
            "forwards those commits to IBus. The engine only sees IBusEngine key events.\n", .{});
    }
}

/// Type Bangla into a GtkEntry through GTK_IM_MODULE=ibus, against a throwaway
/// engine: in a nested mutter (GDK_BACKEND=wayland) when available, else on
/// the current DISPLAY. Standalone mutter has no gnome-shell IM bridge, so this
/// forces the IBus GTK module, which is the path that can actually be driven.
fn waylandType(t: *Tool, repo: []const u8, ime: []const u8, type_bin: []const u8) !void {
    const xml = try writeComponentXml(t, repo, ime);
    var engine = try Engine.start(t, ime, xml);
    defer engine.stop(t);

    // GtkIMContext talks to the session's current engine, not a private IC.
    if (!ok(t, &.{ "ibus", "engine", "byakaron" })) return fail("ibus engine byakaron failed", .{});
    std.debug.print(">>> ibus engine byakaron\n", .{});

    if (haveCmd(t, "mutter")) {
        std.debug.print("\n--- nested Wayland compositor (mutter --headless) ---\n", .{});
        const wl_name = "byakaron-wl-type";
        if (try startMutter(t, wl_name)) |m| {
            var mutter = m;
            defer mutter.kill(t.io);
            // timeout: GTK4 + IBus + a nested compositor can block in
            // gtk_application_run. 25s is well above a passing X11 run (~5s).
            const code = try runWith(t, &.{ "timeout", "25", type_bin }, &.{
                .{ "WAYLAND_DISPLAY", wl_name },
                .{ "GDK_BACKEND", "wayland" },
                .{ "GTK_IM_MODULE", "ibus" },
                .{ "GTK_A11Y", "none" },
            }, &.{"DISPLAY"});
            if (code == 0) {
                std.debug.print("\n=== wayland type test finished (nested mutter) ===\n", .{});
                return;
            }
            std.debug.print("note: nested Wayland typing failed or timed out; falling back to the session display\n", .{});
        } else {
            std.debug.print("note: mutter did not publish WAYLAND_DISPLAY={s}\n", .{wl_name});
        }
    } else {
        std.debug.print("\nnote: mutter not installed; typing against the current display instead\n", .{});
    }

    const display = t.env.get("DISPLAY") orelse "";
    if (display.len == 0) return fail("no DISPLAY and nested Wayland failed", .{});
    std.debug.print("\n--- GtkEntry typing on DISPLAY={s} ---\n", .{display});
    const code = try runWith(t, &.{type_bin}, &.{ .{ "GTK_IM_MODULE", "ibus" }, .{ "GTK_A11Y", "none" } }, &.{});
    if (code != 0) return fail("GtkEntry typing test failed ({d})", .{code});
    std.debug.print("\n=== wayland type test finished (session display) ===\n", .{});
}

/// A headless compositor with a virtual monitor and a private WAYLAND_DISPLAY,
/// so it cannot replace the running GNOME session. null when it never
/// publishes its socket.
fn startMutter(t: *Tool, name: []const u8) !?Child {
    var child = try std.process.spawn(t.io, .{
        .argv = &.{ "mutter", "--wayland", "--headless", "--no-x11", "--wayland-display", name, "--virtual-monitor", "1280x720", "--sm-disable" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = t.env,
    });
    const runtime = t.env.get("XDG_RUNTIME_DIR") orelse blk: {
        const uid = capture(t, &.{ "id", "-u" }) orelse "0";
        break :blk try std.fmt.allocPrint(t.arena, "/run/user/{s}", .{uid});
    };
    const socket = try join(t, &.{ runtime, name });
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        if (exists(t.io, socket)) return child;
        if (!alive(t, &child)) break;
        try t.io.sleep(.fromMilliseconds(100), .awake);
    }
    child.kill(t.io);
    return null;
}

/// A private Xvfb + dbus + ibus-daemon, for CI and for desktops where the
/// session daemon would follow real focus. Matches the working wayland-e2e
/// pattern: fixed IBUS_ADDRESS under a 0700 XDG_RUNTIME_DIR.
const Session = struct {
    xvfb: ?Child = null,
    ibus: ?Child = null,
    dbus_pid: ?[]const u8 = null,
    runtime: []const u8 = "",
    ibus_log: []const u8 = "",

    fn start(s: *Session, t: *Tool) !void {
        std.debug.print("=== starting headless ibus (Xvfb + dbus) ===\n", .{});
        if (!haveCmd(t, "Xvfb") or !haveCmd(t, "ibus-daemon")) {
            return fail("Xvfb and ibus-daemon are required for the IME test in CI\n       install: xvfb ibus dbus-x11", .{});
        }

        // Private runtime per Session. Reusing the install-matrix's
        // XDG_RUNTIME_DIR collides: apt/ibus may already have bound
        // $XDG_RUNTIME_DIR/ibus.sock ("Address already in use").
        // Include nanotime: inside Docker `exec` the tool is often PID 1.
        const runtime = try std.fmt.allocPrint(t.arena, "/tmp/byk-ibus-{d}-{d}", .{
            std.os.linux.getpid(),
            std.Io.Timestamp.now(t.io, .awake).nanoseconds,
        });
        Io.Dir.cwd().deleteTree(t.io, runtime) catch {};
        Io.Dir.cwd().createDirPath(t.io, runtime) catch {};
        try t.env.put("XDG_RUNTIME_DIR", runtime);
        s.runtime = runtime;
        _ = ok(t, &.{ "chmod", "700", runtime });
        if (t.env.get("HOME") == null) try t.env.put("HOME", runtime);
        // Avoid at-spi / portal side channels fighting the private bus.
        try t.env.put("NO_AT_BRIDGE", "1");
        try t.env.put("GTK_USE_PORTAL", "0");

        var n: u32 = 99;
        // GitHub runners may already have something on :99; pick a free slot.
        while (exists(t.io, try std.fmt.allocPrint(t.arena, "/tmp/.X{d}-lock", .{n}))) n += 1;
        const display = try std.fmt.allocPrint(t.arena, ":{d}", .{n});
        try t.env.put("DISPLAY", display);

        s.xvfb = try std.process.spawn(t.io, .{
            .argv = &.{ "Xvfb", display, "-screen", "0", "1024x768x24", "-nolisten", "tcp" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = t.env,
        });
        try t.io.sleep(.fromMilliseconds(400), .awake);
        if (!alive(t, &s.xvfb.?)) return fail("Xvfb failed to start", .{});

        const dbus = capture(t, &.{ "dbus-launch", "--sh-syntax" }) orelse return fail("dbus-launch failed", .{});
        const address = shellVar(dbus, "DBUS_SESSION_BUS_ADDRESS") orelse return fail("dbus-launch printed no address", .{});
        try t.env.put("DBUS_SESSION_BUS_ADDRESS", address);
        if (shellVar(dbus, "DBUS_SESSION_BUS_PID")) |pid| {
            try t.env.put("DBUS_SESSION_BUS_PID", pid);
            s.dbus_pid = pid;
        }

        // Prefer foreground (--daemonize=no). Some ibus builds still fork/replace
        // and leave our Child as a zombie while the real daemon is reparented to
        // init — readiness must not treat that as failure (see wait loop).
        // No --replace: it forces a second process and a zombie parent under us.
        const sock = try join(t, &.{ runtime, "ibus.sock" });
        _ = ok(t, &.{ "rm", "-f", sock });
        const ibus_address = try std.fmt.allocPrint(t.arena, "unix:path={s}", .{sock});
        try t.env.put("IBUS_ADDRESS", ibus_address);
        s.ibus_log = try join(t, &.{ runtime, "ibus.log" });

        // Keep a live Child (no short-lived shell): SIGHUP and missing nohup are
        // common container footguns. stderr → log via shell exec redirection.
        const start_cmd = try std.fmt.allocPrint(t.arena,
            \\exec ibus-daemon --daemonize=no --address='{s}' --panel disable --cache none >'{s}' 2>&1
        , .{ ibus_address, s.ibus_log });
        s.ibus = try std.process.spawn(t.io, .{
            .argv = &.{ "sh", "-c", start_cmd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = t.env,
        });

        // Ready when `ibus list-engine` talks to IBUS_ADDRESS — not when Child is
        // alive. A daemonized/replaced parent becomes zombie (~0.7s) while the
        // bus is still coming up; breaking on !alive caused false failures.
        var i: usize = 0;
        while (i < 120) : (i += 1) {
            if (ok(t, &.{ "ibus", "list-engine" })) {
                std.debug.print(">>> ibus ready on DISPLAY={s}\n", .{display});
                return;
            }
            if (s.ibus) |*c| {
                if (!alive(t, c)) {
                    // Reap zombie parent; daemon (if any) is still on IBUS_ADDRESS.
                    _ = c.wait(t.io) catch {};
                    s.ibus = null;
                }
            }
            try t.io.sleep(.fromMilliseconds(250), .awake);
        }
        // Absolute path: Dir.cwd().readFileAlloc often fails on /tmp/... paths.
        if (capture(t, &.{ "cat", s.ibus_log })) |log| {
            if (log.len > 0) std.debug.print("ibus-daemon log:\n{s}\n", .{log});
        }
        if (capture(t, &.{ "sh", "-c", "ps -ef | grep -E '[i]bus|[X]vfb' || true" })) |ps| {
            if (ps.len > 0) std.debug.print("processes:\n{s}\n", .{ps});
        }
        return fail("ibus-daemon never answered 'ibus list-engine'", .{});
    }

    fn stop(s: *Session, t: *Tool) void {
        // Prefer a clean exit on our bus; fall back to killing anything we started.
        _ = ok(t, &.{ "ibus", "exit" });
        if (s.ibus) |*c| c.kill(t.io);
        s.ibus = null;
        if (s.runtime.len > 0) {
            _ = ok(t, &.{
                "sh", "-c",
                \\for p in $(pgrep -x ibus-daemon); do
                \\  grep -qsa "XDG_RUNTIME_DIR=$0" /proc/$p/environ 2>/dev/null && kill "$p" 2>/dev/null
                \\done
                \\true
            , s.runtime });
        }
        if (s.xvfb) |*c| c.kill(t.io);
        s.xvfb = null;
        if (s.dbus_pid) |pid| _ = ok(t, &.{ "kill", pid });
        s.dbus_pid = null;
    }
};

/// `NAME='value';` from `dbus-launch --sh-syntax` output.
fn shellVar(out: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or line[name.len] != '=') continue;
        var v = line[name.len + 1 ..];
        if (v.len > 0 and v[0] == '\'') {
            v = v[1..];
            return v[0 .. std.mem.indexOfScalar(u8, v, '\'') orelse return null];
        }
        return v[0 .. std.mem.indexOfScalar(u8, v, ';') orelse v.len];
    }
    return null;
}

// ---------------------------------------------------------------------------
// tested / install-matrix
// ---------------------------------------------------------------------------

fn pass(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  ok   " ++ fmt ++ "\n", args);
}

fn bad(failures: *u32, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  FAIL " ++ fmt ++ "\n", args);
    failures.* += 1;
}

/// Check an *installed* Byakaron (.deb or `install-linux`): files in place, no
/// missing libraries, and the IME test typing through the installed engine, not
/// a build-tree one. Starts its own Xvfb + dbus + ibus-daemon, so it runs on a
/// CI runner or in a container with no desktop. `ibus engine byakaron` makes the
/// daemon launch the <exec> from /usr/share/ibus/component/byakaron.xml, which
/// is what a user gets. Needs: xvfb, dbus-x11, ibus.
fn tested(t: *Tool, a: []const []const u8) !u8 {
    const ime_test = a[0];
    const want_version = if (a.len == 2) a[1] else "";
    const component = xmldir ++ "/byakaron.xml";
    var failures: u32 = 0;

    // Containers default to the C locale, which prints every Bangla letter as "?".
    if (t.env.get("LC_ALL") == null) try t.env.put("LC_ALL", "C.UTF-8");

    std.debug.print("=== installed files ===\n", .{});
    for ([_][]const u8{
        component,
        icondir ++ "/byakaron.svg",
        desktopdir ++ "/" ++ app_id ++ ".desktop",
        schemadir ++ "/" ++ app_id ++ ".gschema.xml",
    }) |f| {
        if (exists(t.io, f)) pass("{s}", .{f}) else bad(&failures, "missing {s}", .{f});
    }
    // The app grid draws this with gdk-pixbuf; 0.1.8's icon failed to load there.
    if (ok(t, &.{ "python3", "-c", "import gi; gi.require_version('GdkPixbuf', '2.0')" })) {
        const loads = ok(t, &.{
            "python3",                  "-c",
            \\import sys, gi; gi.require_version('GdkPixbuf', '2.0')
            \\from gi.repository import GdkPixbuf
            \\GdkPixbuf.Pixbuf.new_from_file_at_size(sys.argv[1], 64, 64)
            ,
            icondir ++ "/byakaron.svg",
        });
        if (loads) pass("icon loads in gdk-pixbuf", .{}) else bad(&failures, "icon does not load in gdk-pixbuf (blank in the app grid)", .{});
    } else {
        std.debug.print("  note python3-gi not installed, icon load not checked\n", .{});
    }
    if (exists(t.io, datadir ++ "/Byakaron.db")) {
        pass("Byakaron.db", .{});
    } else {
        std.debug.print("  note Byakaron.db not installed (spell-check off, typing unaffected)\n", .{});
    }

    const xml = Io.Dir.cwd().readFileAlloc(t.io, component, t.arena, .limited(1024 * 1024)) catch "";
    const engine: []const u8 = blk: {
        const open = "<exec>";
        const at = std.mem.indexOf(u8, xml, open) orelse break :blk "";
        const rest = xml[at + open.len ..];
        break :blk rest[0 .. std.mem.indexOfAny(u8, rest, " <") orelse rest.len];
    };
    const app = capture(t, &.{ "sh", "-c", "command -v byakaron" }) orelse "";
    if (engine.len > 0 and ok(t, &.{ "test", "-x", engine })) pass("engine {s}", .{engine}) else bad(&failures, "engine not executable: '{s}'", .{engine});
    if (app.len > 0) pass("app {s}", .{app}) else bad(&failures, "app 'byakaron' not on PATH", .{});

    {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(t.arena, "ldd");
        if (engine.len > 0) try argv.append(t.arena, engine);
        if (app.len > 0) try argv.append(t.arena, app);
        var missing: u32 = 0;
        if (std.process.run(t.arena, t.io, .{ .argv = argv.items, .environ_map = t.env })) |r| {
            for ([_][]const u8{ r.stdout, r.stderr }) |text| {
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |l| {
                    if (std.mem.indexOf(u8, l, "not found") != null) missing += 1;
                }
            }
        } else |_| {}
        if (missing == 0) pass("no missing libraries", .{}) else bad(&failures, "{d} missing libraries", .{missing});
    }

    if (app.len > 0) {
        const got = capture(t, &.{ app, "--version" }) orelse "";
        const expected = try std.fmt.allocPrint(t.arena, "byakaron {s}", .{want_version});
        if (want_version.len == 0 or std.mem.eql(u8, got, expected)) {
            pass("app version: {s}", .{got});
        } else {
            bad(&failures, "app version: '{s}', expected '{s}'", .{ got, expected });
        }
    }

    std.debug.print("\n=== IME test through the installed engine ===\n", .{});
    if (!exists(t.io, ime_test)) {
        bad(&failures, "IME test binary not found: {s} (zig build linux-test)", .{ime_test});
    } else {
        var session: Session = .{};
        defer session.stop(t);
        if (session.start(t)) {
            const engines = capture(t, &.{ "ibus", "list-engine" }) orelse "";
            if (std.mem.indexOf(u8, engines, "byakaron") == null) {
                bad(&failures, "byakaron not in ibus list-engine", .{});
            } else {
                pass("registered with ibus-daemon", .{});
                const r = std.process.run(t.arena, t.io, .{
                    .argv = &.{ime_test},
                    .stdout_limit = .limited(16 * 1024 * 1024),
                    .stderr_limit = .limited(16 * 1024 * 1024),
                    .environ_map = t.env,
                }) catch |err| blk: {
                    bad(&failures, "cannot run {s}: {t}", .{ ime_test, err });
                    break :blk null;
                };
                if (r) |res| {
                    const status: u8 = switch (res.term) {
                        .exited => |c| c,
                        else => 1,
                    };
                    const log = try std.mem.concat(t.arena, u8, &.{ res.stdout, res.stderr });
                    var lines = std.mem.splitScalar(u8, log, '\n');
                    var all: std.ArrayList([]const u8) = .empty;
                    while (lines.next()) |l| {
                        try all.append(t.arena, l);
                        for ([_][]const u8{ "  ok", "  FAIL", "  skip", "       expected", "ime test", "ime_test" }) |p| {
                            if (std.mem.startsWith(u8, l, p)) {
                                std.debug.print("{s}\n", .{l});
                                break;
                            }
                        }
                    }
                    if (status != 0) {
                        std.debug.print("  --- last lines of the IME session log:\n", .{});
                        const tail = if (all.items.len > 16) all.items[all.items.len - 16 ..] else all.items;
                        for (tail) |l| if (l.len > 0) std.debug.print("  | {s}\n", .{l});
                    }
                    // 77 is the test's "engine unreachable" skip: for an install that is a failure.
                    if (status != 0) bad(&failures, "IME test exited {d}", .{status});
                }
            }
        } else |_| {
            bad(&failures, "could not start a private Xvfb + ibus-daemon (apt install xvfb dbus-x11 ibus)", .{});
        }
    }

    std.debug.print("\n=== app opens its window ===\n", .{});
    // No session bus on purpose: the app must not depend on one, and a private
    // bus only adds a ~25 s portal wait. Needs xwininfo (x11-utils).
    if (app.len > 0 and haveCmd(t, "xwininfo") and haveCmd(t, "Xvfb")) {
        var n: u32 = 150;
        while (exists(t.io, try std.fmt.allocPrint(t.arena, "/tmp/.X{d}-lock", .{n}))) n += 1;
        const display = try std.fmt.allocPrint(t.arena, ":{d}", .{n});
        var env = try t.env.clone(t.arena);
        try env.put("DISPLAY", display);
        try env.put("GDK_BACKEND", "x11");
        try env.put("NO_AT_BRIDGE", "1");
        try env.put("GTK_USE_PORTAL", "0");
        try env.put("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/bus");

        var xvfb = try std.process.spawn(t.io, .{
            .argv = &.{ "Xvfb", display, "-screen", "0", "1024x768x24", "-nolisten", "tcp" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = &env,
        });
        defer xvfb.kill(t.io);
        try t.io.sleep(.fromMilliseconds(500), .awake);
        var app_child = try std.process.spawn(t.io, .{
            .argv = &.{app},
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = &env,
        });
        defer app_child.kill(t.io);
        var shown = false;
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            if (std.process.run(t.arena, t.io, .{ .argv = &.{ "xwininfo", "-root", "-tree" }, .environ_map = &env })) |r| {
                if (std.mem.indexOf(u8, r.stdout, "\"Spelling\"") != null) {
                    shown = true;
                    break;
                }
            } else |_| {}
            if (!alive(t, &app_child)) break;
            try t.io.sleep(.fromMilliseconds(500), .awake);
        }
        if (shown) pass("app window shown", .{}) else bad(&failures, "app window did not appear (or the app exited)", .{});
    } else {
        std.debug.print("  note xwininfo/Xvfb not installed, app window not checked\n", .{});
    }

    std.debug.print("\n", .{});
    if (failures > 0) {
        std.debug.print("INSTALLED CHECK FAILED ({d})\n", .{failures});
        return 1;
    }
    std.debug.print("installed check passed\n", .{});
    return 0;
}

/// Install the *local* .deb in clean containers, the way apt does for a user,
/// then run `tested` inside each (files, icon, app window, typing through the
/// installed engine). `deb` is the .deb or a directory holding one. Images
/// default to ubuntu 20.04 / 22.04 / 24.04 and debian:bookworm (what Raspberry
/// Pi OS 64-bit is built on); the .deb's CPU must match the Docker host's. The
/// IME test binary must be built for glibc 2.31 (`zig build linux-test`).
/// `--tool` is a static build of this program, so it runs on any image.
fn installMatrix(t: *Tool, a: []const []const u8) !u8 {
    const ime_test = a[0];
    var tool: ?[]const u8 = null;
    var images: std.ArrayList([]const u8) = .empty;
    for (a[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--tool=")) tool = arg["--tool=".len..] else try images.append(t.arena, arg);
    }
    if (images.items.len == 0) {
        try images.appendSlice(t.arena, &.{ "ubuntu:20.04", "ubuntu:22.04", "ubuntu:24.04", "debian:bookworm" });
    }
    if (!haveCmd(t, "docker")) return fail("docker is required", .{});
    if (!exists(t.io, ime_test)) return fail("{s} is not an executable", .{ime_test});

    const cwd = Io.Dir.cwd();
    var deb = a[1];
    if (cwd.statFile(t.io, deb, .{})) |st| {
        if (st.kind == .directory) {
            var dir = try cwd.openDir(t.io, deb, .{ .iterate = true });
            defer dir.close(t.io);
            var it = dir.iterate();
            var found: ?[]const u8 = null;
            while (try it.next(t.io)) |e| {
                if (std.mem.endsWith(u8, e.name, ".deb")) found = try t.arena.dupe(u8, e.name);
            }
            deb = try join(t, &.{ deb, found orelse return fail("no .deb in {s}", .{deb}) });
        }
    } else |_| return fail("{s} does not exist", .{deb});

    // byakaron_<version>_<arch>.deb
    const base = std.fs.path.basename(deb);
    const version = blk: {
        var parts = std.mem.splitScalar(u8, base, '_');
        _ = parts.next();
        break :blk parts.next() orelse "";
    };
    const self_exe = try std.process.executablePathAlloc(t.io, t.arena);

    // Under apps/linux/build, not /tmp: snap-packaged Docker cannot mount /tmp.
    const here = try std.process.currentPathAlloc(t.io, t.arena);
    const work = try join(t, &.{ here, "apps/linux/build/install-matrix" });
    cwd.deleteTree(t.io, work) catch {};
    try cwd.createDirPath(t.io, work);
    defer cwd.deleteTree(t.io, work) catch {};

    try installFile(t, "755", ime_test, try join(t, &.{ work, "ime-test" }));
    try installFile(t, "755", tool orelse self_exe, try join(t, &.{ work, "tool" }));
    try installFile(t, "644", deb, try join(t, &.{ work, "byakaron.deb" }));
    try writeFile(t, try join(t, &.{ work, "inside.sh" }), matrix_inside, "755");

    const machine = capture(t, &.{ "uname", "-m" }) orelse "?";
    var failed: std.ArrayList([]const u8) = .empty;
    for (images.items) |image| {
        std.debug.print("=== {s} ({s}) with {s}\n", .{ image, machine, base });
        const r = std.process.run(t.arena, t.io, .{
            .argv = &.{ "docker", "run", "--rm", "-v", try std.fmt.allocPrint(t.arena, "{s}:/w:ro", .{work}), image, "bash", "/w/inside.sh", version },
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024 * 1024),
            .environ_map = t.env,
        }) catch |err| {
            std.debug.print("  FAIL docker: {t}\n", .{err});
            try failed.append(t.arena, image);
            continue;
        };
        const good = r.term.success();
        const log = try std.mem.concat(t.arena, u8, &.{ r.stdout, r.stderr });
        const keep: []const []const u8 = if (good)
            &.{ "  >>>", "  ok", "  note", "installed check" }
        else
            &.{ "  >>>", "  FAIL", "       expected", "error", "INSTALLED", "ibus", "Xvfb", "processes:", "starting headless" };
        var shown: u32 = 0;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |l| {
            for (keep) |p| {
                if (std.mem.indexOf(u8, l, p) != null and (good or shown < 15)) {
                    std.debug.print("{s}\n", .{l});
                    shown += 1;
                    break;
                }
            }
        }
        if (!good) try failed.append(t.arena, image);
    }

    std.debug.print("\n", .{});
    if (failed.items.len > 0) {
        std.debug.print("INSTALL MATRIX FAILED:", .{});
        for (failed.items) |f| std.debug.print(" {s}", .{f});
        std.debug.print("\n", .{});
        return 1;
    }
    std.debug.print("install matrix passed:", .{});
    for (images.items) |f| std.debug.print(" {s}", .{f});
    std.debug.print("\n", .{});
    return 0;
}

const matrix_inside =
    \\#!/bin/bash
    \\export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
    \\# Do not set XDG_RUNTIME_DIR before apt: ibus's postinst can bind
    \\# $XDG_RUNTIME_DIR/ibus.sock and then Session.start fails with EADDRINUSE.
    \\apt-get update -qq >/dev/null
    \\# ibus explicitly: the .deb Depends on it, but pull the daemon/tools first so
    \\# a failed dependency resolution is obvious before we install Byakaron.
    \\apt-get install -y -qq xvfb dbus-x11 x11-utils ibus \
    \\    python3-gi gir1.2-gdkpixbuf-2.0 librsvg2-common >/dev/null 2>&1 \
    \\    || { echo "  FAIL could not install the test tools"; exit 1; }
    \\echo "  >>> apt install /w/byakaron.deb"
    \\apt-get install -y -qq /w/byakaron.deb > /tmp/install.log 2>&1 \
    \\    || { echo "  FAIL apt install of the .deb:"; tail -15 /tmp/install.log; exit 1; }
    \\exec /w/tool tested /w/ime-test "$1"
    \\
;

// ---------------------------------------------------------------------------
// wayland-e2e
// ---------------------------------------------------------------------------

/// Type into GTK3 and GTK4 apps on a real GNOME Shell Wayland session, without
/// logging out of the desktop. Starts a *private* `gnome-shell --headless
/// --wayland` with its own D-Bus, dconf, runtime dir and ibus-daemon (input
/// source set to Byakaron), registers the build-tree engine, and opens a GTK
/// window natively on that Wayland display. Keys and a click go in through
/// org.gnome.Mutter.RemoteDesktop, so they take the same path as a real keyboard
/// on an "Ubuntu on Wayland" login: text-input-v3 -> GNOME Shell -> IBus ->
/// byakaron-ibus. Nothing touches the running desktop; everything it starts is
/// stopped by runtime dir afterwards.
///
/// Needs gnome-shell (46 tested) and python3-gi with GTK 3 and 4.
fn waylandE2e(t: *Tool, repo: []const u8, engine: []const u8) !u8 {
    if (!haveCmd(t, "gnome-shell")) {
        std.debug.print("skip: gnome-shell not installed\n", .{});
        return 0;
    }
    if (!exists(t.io, engine)) return fail("{s} is missing (zig build linux)", .{engine});

    const linux_dir = try join(t, &.{ repo, "apps/linux" });
    // Short paths: Unix socket names (at-spi, gvfs) must fit in 108 bytes.
    const w = try join(t, &.{ linux_dir, "build/gnome-wayland" });
    const runtime = try join(t, &.{ w, "run" });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(t.io, w) catch {};
    try cwd.createDirPath(t.io, runtime);
    for ([_][]const u8{ "config", "data", "cache" }) |d| try cwd.createDirPath(t.io, try join(t, &.{ w, d }));
    try run(t, &.{ "chmod", "700", runtime });

    const xml = try join(t, &.{ w, "byakaron.xml" });
    try render(t, try join(t, &.{ linux_dir, "Resources/byakaron.xml.in" }), xml, &.{
        .{ "@BYK_EXEC@", engine },
        .{ "@BYK_ICON@", "input-keyboard" },
        .{ "@BYK_SETUP@", "" },
    });

    // The spelling-correction case needs a Byakaron.db the engine can open.
    const spell_present = blk: {
        if (t.env.get("BYAKARON_SPELL_DB")) |db| if (db.len > 0 and exists(t.io, db)) break :blk true;
        break :blk exists(t.io, datadir ++ "/Byakaron.db");
    };

    // The build tree's compiled schema, so gsettings and the engine agree on keys
    // (the sandbox has its own dconf, the desktop's settings are not touched).
    try t.env.put("GSETTINGS_SCHEMA_DIR", try join(t, &.{ repo, "zig-out/share/glib-2.0/schemas" }));
    try t.env.put("BYK_SETTINGS_TEST", "1");
    try t.env.put("W", w);
    try t.env.put("RUN", runtime);
    try t.env.put("ENGINE", engine);
    try t.env.put("XML", xml);
    try t.env.put("PROJECT_ROOT", linux_dir);
    try t.env.put("BYK_SPELL_DB_PRESENT", if (spell_present) "1" else "0");
    try t.env.put("XDG_RUNTIME_DIR", runtime);
    try t.env.put("XDG_CONFIG_HOME", try join(t, &.{ w, "config" }));
    try t.env.put("XDG_DATA_HOME", try join(t, &.{ w, "data" }));
    try t.env.put("XDG_CACHE_HOME", try join(t, &.{ w, "cache" }));
    // Whatever forces a backend or IM module in the caller's session must not leak in.
    for ([_][]const u8{
        "DISPLAY",         "WAYLAND_DISPLAY", "GTK_IM_MODULE", "QT_IM_MODULE",    "XMODIFIERS",
        "SESSION_MANAGER", "IBUS_ADDRESS",    "GDK_BACKEND",   "QT_QPA_PLATFORM", "CLUTTER_BACKEND",
    }) |k| _ = t.env.swapRemove(k);

    const code = try runExit(t, &.{ "dbus-run-session", "--", "bash", "-c", e2e_inside });

    // Stop whatever the session left behind, found by its runtime dir.
    _ = ok(t, &.{
        "sh", "-c",
        \\for p in $(pgrep -u "$(id -u)"); do
        \\    grep -qsa "XDG_RUNTIME_DIR=$RUN" /proc/$p/environ 2>/dev/null && kill "$p" 2>/dev/null
        \\done
        \\true
    });
    std.debug.print("\n{s}\n", .{if (code == 0) "gnome wayland test passed" else "GNOME WAYLAND TEST FAILED"});
    return code;
}

// Runs inside `dbus-run-session`: the private bus is what gnome-shell, the
// ibus-daemon and the test all share. Its exit status is the number of failures.
const e2e_inside =
    \\set -u
    \\sandboxed() { for p in $(pgrep -x "$1"); do grep -qsa "XDG_RUNTIME_DIR=$RUN" /proc/$p/environ && echo $p; done; }
    \\
    \\gsettings set org.gnome.desktop.input-sources sources "[(\"ibus\", \"byakaron\")]"
    \\
    \\# Our daemon on a fixed address. With --no-x11 the shell sees it and does not
    \\# spawn its own (with X11 it starts a second, --replace one for XIM).
    \\export IBUS_ADDRESS="unix:path=$RUN/ibus.sock"
    \\ibus-daemon --address="$IBUS_ADDRESS" --panel disable --cache none >"$W/ibus.log" 2>&1 &
    \\for _ in $(seq 1 60); do ibus list-engine >/dev/null 2>&1 && break; sleep 0.25; done
    \\"$ENGINE" --xml "$XML" >"$W/engine.log" 2>&1 &
    \\sleep 2
    \\
    \\gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x800 \
    \\    --wayland-display byk-wl >"$W/shell.log" 2>&1 &
    \\shell=$!
    \\for _ in $(seq 1 120); do [[ -S "$RUN/byk-wl" ]] && break; sleep 0.25; done
    \\export WAYLAND_DISPLAY=byk-wl
    \\sleep 5
    \\ibus engine byakaron
    \\echo ">>> gnome-shell $(gnome-shell --version | cut -d" " -f3) headless Wayland, ibus engine: $(ibus engine 2>&1)"
    \\[[ -n "$(sandboxed byakaron-ibus)" ]] || { echo "error: build-tree engine not running"; tail -3 "$W/engine.log"; exit 1; }
    \\
    \\fails=0
    \\for ver in 3 4; do
    \\    out="$W/text$ver.txt"; : >"$out"
    \\    python3 "$PROJECT_ROOT/tests/wayland_textapp.py" $ver "$out" >"$W/app$ver.log" 2>&1 &
    \\    app=$!
    \\    for _ in $(seq 1 60); do grep -q "^\[app\]" "$W/app$ver.log" && break; sleep 0.5; done
    \\    sleep 1
    \\    grep "^\[app\]" "$W/app$ver.log" || { echo "error: GTK$ver app did not start"; tail -3 "$W/app$ver.log"; fails=$((fails+1)); continue; }
    \\    python3 "$PROJECT_ROOT/tests/wayland_rdtest.py" "GTK$ver/Wayland" cat "$out" || fails=$((fails+1))
    \\    kill $app; sleep 1
    \\done
    \\kill $shell 2>/dev/null; sleep 1
    \\exit $fails
    \\
;

// ---------------------------------------------------------------------------
// package-flatpak
// ---------------------------------------------------------------------------

/// Bundle the GTK companion app as a Flatpak. The IBus engine is NOT in here:
/// ibus-daemon only scans /usr/share/ibus/component, which a sandbox cannot
/// register. The .deb remains the IME artefact; this is the app for people who
/// want Spelling / Layout / Setup from Flathub-style packaging.
///
/// Uses org.gnome.Platform as both runtime and SDK so a box that already has
/// the Platform, and not org.gnome.Sdk, can still pack the binary we already
/// built. Byakaron.db is omitted (364 MB; the app runs without it).
fn packageFlatpak(t: *Tool, a: []const []const u8) !void {
    const repo = a[0];
    const app = a[1];
    const out_dir = a[2];
    const runtime = "org.gnome.Platform";
    const branch = if (t.env.get("FLATPAK_BRANCH")) |b| (if (b.len > 0) b else "49") else "49";

    if (!haveCmd(t, "flatpak")) return fail("flatpak is not installed", .{});
    if (!haveCmd(t, "rsvg-convert")) return fail("rsvg-convert is not installed (apt install librsvg2-bin)", .{});
    const machine = if (t.env.get("BYK_FLATPAK_ARCH")) |m| m else capture(t, &.{ "uname", "-m" }) orelse "x86_64";
    const info = try std.fmt.allocPrint(t.arena, "runtime/{s}/{s}/{s}", .{ runtime, machine, branch });
    if (!ok(t, &.{ "flatpak", "info", info })) {
        return fail("{s}//{s} is not installed\n       flatpak install flathub {s}//{s}", .{ runtime, branch, runtime, branch });
    }
    try assertGlibc(t, app);

    const res = try join(t, &.{ repo, "apps/linux/Resources" });
    const build_dir = try join(t, &.{ repo, "apps/linux/build/flatpak" });
    const appdir = try join(t, &.{ build_dir, "appdir" });
    const export_repo = try join(t, &.{ build_dir, "repo" });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(t.io, build_dir) catch {};
    try cwd.createDirPath(t.io, build_dir);

    std.debug.print(">>> flatpak build-init (runtime=SDK={s}//{s})...\n", .{ runtime, branch });
    // The SDK slot is the Platform on purpose: we copy a prebuilt binary and do
    // not compile inside the sandbox, so org.gnome.Sdk is not required.
    try run(t, &.{ "flatpak", "build-init", appdir, app_id, runtime, runtime, branch });

    std.debug.print(">>> installing binary, desktop file, icon...\n", .{});
    try flatpakInstall(t, appdir, "755", app, "/app/bin/byakaron");

    const desktop = try std.fmt.allocPrint(t.arena,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Byakaron
        \\GenericName=Bangla Input & Spell Checker
        \\Comment=Type Bangla phonetically and check spelling
        \\Exec=byakaron
        \\Icon={s}
        \\Terminal=false
        \\Categories=Utility;TextTools;
        \\Keywords=Bangla;Bengali;spell;spelling;input;phonetic;avro;keyboard;
        \\StartupNotify=true
        \\StartupWMClass={s}
        \\
    , .{ app_id, app_id });
    const desktop_file = try join(t, &.{ build_dir, app_id ++ ".desktop" });
    try writeFile(t, desktop_file, desktop, "644");
    try flatpakInstall(t, appdir, "644", desktop_file, "/app/share/applications/" ++ app_id ++ ".desktop");
    try flatpakInstall(t, appdir, "644", try join(t, &.{ res, app_id ++ ".metainfo.xml" }), "/app/share/metainfo/" ++ app_id ++ ".metainfo.xml");

    // Flatpak's export validator often rejects this SVG (gdk-pixbuf in the
    // export environment has no SVG loader). A PNG is what GNOME Software shows.
    //
    // Installed twice per size: the app id is what gets exported to the host
    // menu, and `byakaron` is the name the app itself asks for (About logo,
    // window icon). Only the first leaves the sandbox; the second resolves inside it.
    for ([_][]const u8{ "128", "256" }) |size| {
        const png = try join(t, &.{ build_dir, try std.fmt.allocPrint(t.arena, "byakaron-{s}.png", .{size}) });
        try run(t, &.{ "rsvg-convert", "-w", size, "-h", size, try join(t, &.{ res, "byakaron.svg" }), "-o", png });
        const dir = try std.fmt.allocPrint(t.arena, "/app/share/icons/hicolor/{s}x{s}/apps", .{ size, size });
        try flatpakInstall(t, appdir, "644", png, try std.fmt.allocPrint(t.arena, "{s}/{s}.png", .{ dir, app_id }));
        try flatpakInstall(t, appdir, "644", png, try std.fmt.allocPrint(t.arena, "{s}/byakaron.png", .{dir}));
    }

    std.debug.print(">>> installing GSettings schema...\n", .{});
    const schemas = try join(t, &.{ build_dir, "schemas" });
    try installFile(t, "644", try join(t, &.{ res, app_id ++ ".gschema.xml" }), try join(t, &.{ schemas, app_id ++ ".gschema.xml" }));
    try run(t, &.{ "glib-compile-schemas", schemas });
    try flatpakInstall(t, appdir, "644", try join(t, &.{ schemas, app_id ++ ".gschema.xml" }), "/app/share/glib-2.0/schemas/" ++ app_id ++ ".gschema.xml");
    try flatpakInstall(t, appdir, "644", try join(t, &.{ schemas, "gschemas.compiled" }), "/app/share/glib-2.0/schemas/gschemas.compiled");

    std.debug.print(">>> build-finish...\n", .{});
    try run(t, &.{
        "flatpak",                    "build-finish",                               appdir,
        "--command=byakaron",         "--share=ipc",                                "--socket=wayland",
        "--socket=fallback-x11",      "--device=dri",                               "--talk-name=ca.desrt.dconf",
        "--filesystem=xdg-run/dconf", "--talk-name=org.freedesktop.portal.Desktop",
    });

    std.debug.print(">>> exporting bundle...\n", .{});
    cwd.deleteTree(t.io, export_repo) catch {};
    try run(t, &.{ "flatpak", "build-export", export_repo, appdir, branch });
    const out = try join(t, &.{ out_dir, app_id ++ ".flatpak" });
    cwd.deleteFile(t.io, out) catch {};
    try run(t, &.{ "flatpak", "build-bundle", export_repo, out, app_id, branch });

    std.debug.print(
        \\
        \\=== Built: {s} ===
        \\
        \\This is the companion app only. The IBus engine still needs the .deb
        \\(or sudo -E zig build install-linux).
        \\
        \\Install the bundle with:
        \\    flatpak install --user {s}
        \\
    , .{ out, out });
}

/// `flatpak build <appdir> install -D -m <mode> <src> <dest>`.
fn flatpakInstall(t: *Tool, appdir: []const u8, mode: []const u8, src: []const u8, dest: []const u8) !void {
    try run(t, &.{ "flatpak", "build", appdir, "install", "-D", "-m", mode, src, dest });
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn fail(comptime fmt: []const u8, args: anytype) error{Failed} {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.Failed;
}

fn isRoot() bool {
    return std.os.linux.geteuid() == 0;
}

fn envIs(t: *Tool, key: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, t.env.get(key) orelse "", value);
}

fn join(t: *Tool, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(t.arena, parts);
}

fn exists(io: Io, p: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

fn pidStr(t: *Tool, pid: Child.Id) []const u8 {
    return std.fmt.allocPrint(t.arena, "{d}", .{pid}) catch "0";
}

/// kill -0 is not enough: an exited, unreaped child is a zombie that still
/// answers it.
fn alive(t: *Tool, child: *Child) bool {
    const pid = child.id orelse return false;
    const path = std.fmt.allocPrint(t.arena, "/proc/{d}/stat", .{pid}) catch return true;
    // `cat`, not a file read: procfs files report size 0.
    const stat = capture(t, &.{ "cat", path }) orelse return false;
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    return !(close + 2 < stat.len and stat[close + 2] == 'Z');
}

/// Run `argv`, inheriting stdio; fail unless it exits 0.
fn run(t: *Tool, argv: []const []const u8) !void {
    const code = try runExit(t, argv);
    if (code != 0) return fail("{s} failed (exit {d})", .{ argv[0], code });
}

/// Run `argv`, inheriting stdio; its exit code (128 + signal when killed).
fn runExit(t: *Tool, argv: []const []const u8) !u8 {
    var child = std.process.spawn(t.io, .{ .argv = argv, .stdin = .ignore, .environ_map = t.env }) catch |err| {
        return fail("cannot run {s}: {t}", .{ argv[0], err });
    };
    return switch (try child.wait(t.io)) {
        .exited => |code| code,
        .signal => |sig| 128 +% @as(u8, @intCast(@backingInt(sig))),
        else => 1,
    };
}

/// Like `runExit`, with `set` added to and `unset` removed from the environment.
fn runWith(t: *Tool, argv: []const []const u8, set: []const [2][]const u8, unset: []const []const u8) !u8 {
    var env = try t.env.clone(t.arena);
    for (unset) |k| _ = env.swapRemove(k);
    for (set) |kv| try env.put(kv[0], kv[1]);
    var child = std.process.spawn(t.io, .{ .argv = argv, .stdin = .ignore, .environ_map = &env }) catch |err| {
        return fail("cannot run {s}: {t}", .{ argv[0], err });
    };
    return switch (try child.wait(t.io)) {
        .exited => |code| code,
        else => 1,
    };
}

/// Run `argv` with its output discarded; true when it succeeded.
fn ok(t: *Tool, argv: []const []const u8) bool {
    var child = std.process.spawn(t.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = t.env,
    }) catch return false;
    const term = child.wait(t.io) catch return false;
    return term.success();
}

/// Trimmed stdout of `argv`, or null when it failed.
fn capture(t: *Tool, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(t.arena, t.io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .environ_map = t.env,
    }) catch return null;
    if (!r.term.success()) return null;
    return std.mem.trim(u8, r.stdout, " \r\n\t");
}

fn haveCmd(t: *Tool, name: []const u8) bool {
    return ok(t, &.{ "sh", "-c", "command -v \"$1\"", "sh", name });
}

/// `install -D -m <mode> src dst`: creates parents, sets the mode.
fn installFile(t: *Tool, mode: []const u8, src: []const u8, dst: []const u8) !void {
    try run(t, &.{ "install", "-D", "-m", mode, src, dst });
}

fn strip(t: *Tool, path: []const u8) void {
    _ = ok(t, &.{ "strip", "--strip-unneeded", path });
}

fn writeFile(t: *Tool, path: []const u8, data: []const u8, mode: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(t.io, d);
    try cwd.writeFile(t.io, .{ .sub_path = path, .data = data });
    try run(t, &.{ "chmod", mode, path });
}

/// Fill in a `.in` template and write it as a 644 file. Every `@BYK_` placeholder
/// must be substituted: an unfilled one ships a broken component.
fn render(t: *Tool, template: []const u8, dst: []const u8, replacements: []const [2][]const u8) !void {
    var text = try Io.Dir.cwd().readFileAlloc(t.io, template, t.arena, .limited(1024 * 1024));
    for (replacements) |r| text = try std.mem.replaceOwned(u8, t.arena, text, r[0], r[1]);
    if (std.mem.indexOf(u8, text, "@BYK_") != null) {
        return fail("unsubstituted @BYK_ placeholder rendering {s}", .{template});
    }
    try writeFile(t, dst, text, "644");
}

/// `.version = "x.y.z"` from build.zig.zon.
fn readVersion(t: *Tool, repo: []const u8) ![]const u8 {
    const zon = try Io.Dir.cwd().readFileAlloc(t.io, try join(t, &.{ repo, "build.zig.zon" }), t.arena, .limited(1024 * 1024));
    var lines = std.mem.splitScalar(u8, zon, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, ".version")) continue;
        const open = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse continue;
        return line[open + 1 .. close];
    }
    return fail("no .version in {s}/build.zig.zon", .{repo});
}

/// The Debian architecture the package is for: BYK_DEB_ARCH (set by the build
/// from -Dlinux-arch), else dpkg's, else derived from the host CPU.
fn debArch(t: *Tool) ![]const u8 {
    if (t.env.get("BYK_DEB_ARCH")) |a| if (a.len > 0) return a;
    if (capture(t, &.{ "dpkg", "--print-architecture" })) |a| if (a.len > 0) return a;
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return fail("cannot tell the Debian architecture; set BYK_DEB_ARCH", .{}),
    };
}

/// Where the system's Fcitx5 loads addons from (…/fcitx5/byakaron.so).
fn fcitxLibdir(t: *Tool) ![]const u8 {
    if (capture(t, &.{ "pkg-config", "--variable=libdir", "Fcitx5Core" })) |d| if (d.len > 0) return d;
    if (capture(t, &.{ "dpkg-architecture", "-qDEB_HOST_MULTIARCH" })) |m| if (m.len > 0) {
        return std.fmt.allocPrint(t.arena, "/usr/lib/{s}", .{m});
    };
    return switch (@import("builtin").cpu.arch) {
        .aarch64 => "/usr/lib/aarch64-linux-gnu",
        else => "/usr/lib/x86_64-linux-gnu",
    };
}
