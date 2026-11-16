#include "update.h"

#include <stdio.h>
#include <string.h>
#include <sys/utsname.h>
#include <sys/wait.h>

gchar *
byk_update_base (void)
{
    const gchar *env = g_getenv ("BYAKARON_UPDATE_BASE");
    if (env != NULL && *env != '\0')
        return g_strdup (env);
    return g_strdup ("https://github.com/nuhulabs/Byakaron-Assets");
}

gchar *
byk_update_tag_from_url (const gchar *url)
{
    static const gchar marker[] = "/releases/tag/";
    const gchar *p;
    gsize n;

    if (url == NULL)
        return NULL;
    p = strstr (url, marker);
    if (p == NULL)
        return NULL;
    p += sizeof marker - 1;
    n = strcspn (p, "/?#\r\n\t ");
    return n > 0 ? g_strndup (p, n) : NULL;
}

/* v<digit> and then only version characters. */
static gboolean
byk_update_tag_ok (const gchar *tag)
{
    if (tag == NULL || tag[0] != 'v' || !g_ascii_isdigit (tag[1]))
        return FALSE;
    for (const gchar *c = tag + 1; *c != '\0'; c++)
        if (!g_ascii_isalnum (*c) && *c != '.' && *c != '-' && *c != '+')
            return FALSE;
    return TRUE;
}

gchar *
byk_update_deb_version (const gchar *tag)
{
    gchar *v, *dash;

    if (!byk_update_tag_ok (tag))
        return NULL;

    /* src/build/linux.zig's debVersion: only the first `-` (the SemVer
     * prerelease) becomes `~`, so dpkg sorts 27.0.0~dev.2 before 27.0.0. */
    v = g_strconcat ("1:", tag + 1, NULL);
    dash = strchr (v, '-');
    if (dash != NULL)
        *dash = '~';
    return v;
}

gchar *
byk_update_arch_version (const gchar *tag)
{
    const gchar *dash;
    GString *v;

    if (!byk_update_tag_ok (tag))
        return NULL;
    dash = strchr (tag, '-');
    if (dash != NULL && !g_ascii_isalpha (dash[1]))
        return NULL;

    /* src/build/linux.zig's archVersion: the first `-` is dropped (vercmp sorts
     * 27.0.0dev.2 before 27.0.0), a later one becomes `_`; pkgrel is 1. */
    v = g_string_new (NULL);
    for (const gchar *c = tag + 1; *c != '\0'; c++) {
        if (*c != '-')
            g_string_append_c (v, *c);
        else if (c != dash)
            g_string_append_c (v, '_');
    }
    g_string_append (v, "-1");
    return g_string_free (v, FALSE);
}

gchar *
byk_update_package_version (BykPackage package, const gchar *tag)
{
    switch (package) {
    case BYK_PACKAGE_DEB:
        return byk_update_deb_version (tag);
    case BYK_PACKAGE_ARCH:
        return byk_update_arch_version (tag);
    default:
        return NULL;
    }
}

gchar *
byk_update_shown_version (BykPackage package, const gchar *version)
{
    gchar *v;

    if (version == NULL)
        return NULL;
    if (package == BYK_PACKAGE_ARCH) {
        /* 27.0.0dev.2-1: drop the pkgrel, put the `-` back before the first
         * letter. */
        gchar *rel = strrchr (version, '-');
        gchar *pkgver = rel != NULL ? g_strndup (version, (gsize) (rel - version)) : g_strdup (version);
        const gchar *letter = pkgver;
        while (*letter != '\0' && !g_ascii_isalpha (*letter))
            letter++;
        if (*letter == '\0' || letter == pkgver)
            return pkgver;
        v = g_strdup_printf ("%.*s-%s", (int) (letter - pkgver), pkgver, letter);
        g_free (pkgver);
        return v;
    }

    const gchar *colon = strchr (version, ':');
    gchar *tilde;
    v = g_strdup (colon != NULL ? colon + 1 : version);
    tilde = strchr (v, '~');
    if (tilde != NULL)
        *tilde = '-';
    return v;
}

gchar *
byk_update_sum_for (const gchar *sums, const gchar *name)
{
    gchar **lines;
    gchar *found = NULL;

    if (sums == NULL || name == NULL)
        return NULL;
    lines = g_strsplit (sums, "\n", -1);
    for (gchar **l = lines; *l != NULL && found == NULL; l++) {
        char hash[65], file[256];
        const char *f;
        /* sha256sum writes "<hash>  <name>", or "<hash> *<name>" in binary mode. */
        if (sscanf (*l, "%64s %255s", hash, file) != 2 || strlen (hash) != 64)
            continue;
        f = file[0] == '*' ? file + 1 : file;
        if (strcmp (f, name) == 0)
            found = g_ascii_strdown (hash, -1);
    }
    g_strfreev (lines);
    return found;
}

/* argv's stdout, trimmed, when it exits 0; NULL otherwise. */
static gchar *
byk_update_run (const gchar *const *argv, gint *exit_status)
{
    gchar *out = NULL;
    gint wait = 0;

    if (exit_status != NULL)
        *exit_status = -1;
    if (!g_spawn_sync (NULL, (gchar **) argv, NULL,
                       G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL,
                       NULL, NULL, &out, NULL, &wait, NULL))
        return NULL;
    if (!WIFEXITED (wait)) {
        g_free (out);
        return NULL;
    }
    if (exit_status != NULL)
        *exit_status = WEXITSTATUS (wait);
    if (WEXITSTATUS (wait) != 0) {
        g_free (out);
        return NULL;
    }
    return g_strstrip (out);
}

gchar *
byk_update_installed_version (BykPackage *package)
{
    static const gchar *const dpkg[] = { "dpkg-query", "-W", "-f=${Version}", "byakaron", NULL };
    static const gchar *const pacman[] = { "pacman", "-Q", "byakaron", NULL };
    const gchar *env = g_getenv ("BYAKARON_INSTALLED_VERSION");
    BykPackage found = BYK_PACKAGE_NONE;
    gchar *v;

    if (env != NULL) {
        v = *env != '\0' ? g_strdup (env) : NULL;
        if (v != NULL)
            found = g_strcmp0 (g_getenv ("BYAKARON_INSTALLED_PACKAGE"), "arch") == 0
                ? BYK_PACKAGE_ARCH : BYK_PACKAGE_DEB;
    } else if ((v = byk_update_run (dpkg, NULL)) != NULL && *v != '\0') {
        found = BYK_PACKAGE_DEB;
    } else {
        g_clear_pointer (&v, g_free);
        /* "byakaron 27.0.0dev.2-1" */
        gchar *line = byk_update_run (pacman, NULL);
        gchar *space = line != NULL ? strchr (line, ' ') : NULL;
        if (space != NULL && space[1] != '\0') {
            v = g_strdup (space + 1);
            found = BYK_PACKAGE_ARCH;
        }
        g_free (line);
    }
    if (package != NULL)
        *package = found;
    return v;
}

gboolean
byk_update_newer (BykPackage package, const gchar *a, const gchar *b)
{
    gint status = -1;
    gchar *out;

    if (a == NULL || b == NULL)
        return FALSE;
    if (package == BYK_PACKAGE_ARCH) {
        /* vercmp prints -1, 0 or 1. */
        const gchar *argv[] = { "vercmp", a, b, NULL };
        out = byk_update_run (argv, &status);
        const gboolean newer = out != NULL && strcmp (out, "1") == 0;
        g_free (out);
        return newer;
    }
    const gchar *argv[] = { "dpkg", "--compare-versions", a, "gt", b, NULL };
    out = byk_update_run (argv, &status);
    g_free (out);
    return status == 0;
}

gchar *
byk_update_package_name (BykPackage package)
{
    if (package == BYK_PACKAGE_ARCH) {
        /* Only an x86_64 Arch package is published (Arch has no ARM images
         * to test one in). */
        struct utsname u;
        if (uname (&u) != 0 || strcmp (u.machine, "x86_64") != 0)
            return NULL;
        return g_strdup ("byakaron_x86_64.pkg.tar.zst");
    }
    if (package != BYK_PACKAGE_DEB)
        return NULL;

    static const gchar *const argv[] = { "dpkg", "--print-architecture", NULL };
    gchar *arch = byk_update_run (argv, NULL);
    gchar *name;

    if (arch == NULL || *arch == '\0') {
        g_free (arch);
        return NULL;
    }
    name = g_strdup_printf ("byakaron_%s.deb", arch);
    g_free (arch);
    return name;
}
