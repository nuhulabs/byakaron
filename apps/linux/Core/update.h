/*
 * Is there a newer Byakaron? The pieces of the app's update check that need no
 * window: where releases live, what a release tag means to dpkg, and the
 * SHA256SUMS lookup. The window part is App/updates.c.
 *
 * Releases are the `.deb`s on nuhulabs/Byakaron-Assets. GitHub's
 * /releases/latest redirects to /releases/tag/<tag> for the newest normal
 * release and skips prereleases, so a prerelease is never offered as an update.
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* https://github.com/nuhulabs/Byakaron-Assets, or BYAKARON_UPDATE_BASE (tests
 * serve releases/latest and releases/download/<tag>/<file> from there). */
gchar *byk_update_base (void);

/* "…/releases/tag/v27.0.0" → "v27.0.0"; NULL when the URL names no tag, as
 * GitHub's redirect does while there is no normal release. */
gchar *byk_update_tag_from_url (const gchar *url);

/* The .deb version a release tag builds, as the packaging writes it:
 * "v27.0.0" → "1:27.0.0", "v27.0.0-dev.2" → "1:27.0.0~dev.2". NULL when the
 * tag is not v<digit>… made of version characters. */
gchar *byk_update_deb_version (const gchar *tag);

/* "1:27.0.0~dev.2" → "27.0.0-dev.2": the version as people know it. */
gchar *byk_update_shown_version (const gchar *deb_version);

/* The SHA-256 that SHA256SUMS text lists for `name`, or NULL. */
gchar *byk_update_sum_for (const gchar *sums, const gchar *name);

/* The byakaron .deb version dpkg has installed; NULL when Byakaron was not
 * installed from a .deb (a build run from zig-out). BYAKARON_INSTALLED_VERSION
 * overrides it for tests. */
gchar *byk_update_installed_version (void);

/* dpkg's ordering: TRUE when `a` is newer than `b`. */
gboolean byk_update_newer (const gchar *a, const gchar *b);

/* "byakaron_amd64.deb" for this machine, or NULL without dpkg. */
gchar *byk_update_deb_name (void);

G_END_DECLS
