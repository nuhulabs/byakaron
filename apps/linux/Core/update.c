#include "update.h"

#include <stdio.h>
#include <string.h>
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

gchar *
byk_update_deb_version (const gchar *tag)
{
    gchar *v, *dash;

    if (tag == NULL || tag[0] != 'v' || !g_ascii_isdigit (tag[1]))
        return NULL;
    for (const gchar *c = tag + 1; *c != '\0'; c++)
        if (!g_ascii_isalnum (*c) && *c != '.' && *c != '-' && *c != '+')
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
byk_update_shown_version (const gchar *deb_version)
{
    const gchar *colon;
    gchar *v, *tilde;

    if (deb_version == NULL)
        return NULL;
    colon = strchr (deb_version, ':');
    v = g_strdup (colon != NULL ? colon + 1 : deb_version);
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
byk_update_installed_version (void)
{
    static const gchar *const argv[] = { "dpkg-query", "-W", "-f=${Version}", "byakaron", NULL };
    const gchar *env = g_getenv ("BYAKARON_INSTALLED_VERSION");
    gchar *v;

    if (env != NULL)
        return *env != '\0' ? g_strdup (env) : NULL;
    v = byk_update_run (argv, NULL);
    if (v != NULL && *v == '\0')
        g_clear_pointer (&v, g_free);
    return v;
}

gboolean
byk_update_newer (const gchar *a, const gchar *b)
{
    const gchar *argv[] = { "dpkg", "--compare-versions", a, "gt", b, NULL };
    gint status = -1;
    gchar *out;

    if (a == NULL || b == NULL)
        return FALSE;
    out = byk_update_run (argv, &status);
    g_free (out);
    return status == 0;
}

gchar *
byk_update_deb_name (void)
{
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
