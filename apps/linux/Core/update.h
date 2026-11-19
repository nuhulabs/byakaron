/*
 * Is there a newer Byakaron? The pieces of the app's update check that need no
 * window: where releases live, what a release tag means to dpkg or pacman,
 * and the SHA256SUMS lookup. The window part is App/updates.c.
 *
 * Releases are the packages on nuhulabs/Byakaron-Assets: a `.deb`, an Arch
 * package and an `.rpm` for each CPU, for every channel. Which release to
 * offer is the shared core's call (byakaron_update_pick, src/Update.zig).
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* Which package manager installed Byakaron. */
typedef enum {
    BYK_PACKAGE_NONE, /* none: a build run from zig-out, or a source install */
    BYK_PACKAGE_DEB,  /* apt and dpkg: Ubuntu, Debian, Raspberry Pi OS */
    BYK_PACKAGE_ARCH, /* pacman: Arch Linux and the systems built on it */
    BYK_PACKAGE_RPM,  /* dnf or zypper: Fedora, RHEL and its rebuilds, openSUSE */
} BykPackage;

/* https://github.com/nuhulabs/Byakaron-Assets, or BYAKARON_UPDATE_BASE (tests
 * serve releases/download/<tag>/<file> from there). */
gchar *byk_update_base (void);

/* The .deb version a release tag builds, as the packaging writes it:
 * "v27.0.0" → "1:27.0.0", "v27.0.0-dev.2" → "1:27.0.0~dev.2". NULL when the
 * tag is not v<digit>… made of version characters. */
gchar *byk_update_deb_version (const gchar *tag);

/* The Arch package version a release tag builds, as src/build/linux.zig's
 * archVersion writes it: "v27.0.0" → "27.0.0-1", "v27.0.0-dev.2" →
 * "27.0.0dev.2-1". NULL for what byk_update_deb_version refuses, and for a
 * prerelease that does not start with a letter (v27.0.0-1). */
gchar *byk_update_arch_version (const gchar *tag);

/* The RPM version-release a release tag builds, as src/build/linux.zig's
 * rpmVersion writes it: "v27.0.0" → "27.0.0-1", "v27.0.0-dev.2" →
 * "27.0.0~dev.2-1". NULL for what byk_update_deb_version refuses. */
gchar *byk_update_rpm_version (const gchar *tag);
/* The release's version as `package` writes it (one of the three above). */
gchar *byk_update_package_version (BykPackage package, const gchar *tag);

/* "1:27.0.0~dev.2" (deb) or "27.0.0dev.2-1" (Arch) → "27.0.0-dev.2": the
 * version as people know it. */
gchar *byk_update_shown_version (BykPackage package, const gchar *version);

/* The SHA-256 that SHA256SUMS text lists for `name`, or NULL. */
gchar *byk_update_sum_for (const gchar *sums, const gchar *name);

/* The installed byakaron package's version, asking dpkg, pacman, then rpm, and
 * in `package` (may be NULL) which one has it. NULL and BYK_PACKAGE_NONE when
 * Byakaron was not installed from a package (a build run from zig-out).
 * BYAKARON_INSTALLED_VERSION overrides it for tests, as a deb version unless
 * BYAKARON_INSTALLED_PACKAGE is "arch" or "rpm". */
gchar *byk_update_installed_version (BykPackage *package);

/* `package`'s ordering (dpkg --compare-versions, pacman's vercmp, rpm's
 * rpm.vercmp): TRUE
 * when `a` is newer than `b`. */
gboolean byk_update_newer (BykPackage package, const gchar *a, const gchar *b);

/* The release file for this machine: "byakaron_amd64.deb" (from dpkg's
 * architecture), "byakaron_x86_64.pkg.tar.zst", "byakaron_aarch64.rpm", or
 * NULL when there is none (no dpkg; a CPU no package is built for). */
gchar *byk_update_package_name (BykPackage package);

G_END_DECLS
