#include "prefs.h"

#include <limits.h>
#include <unistd.h>

void
byk_prefs_init_schema_dir (void)
{
    if (g_getenv ("GSETTINGS_SCHEMA_DIR") != NULL)
        return;

    char exe[PATH_MAX];
    const ssize_t n = readlink ("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0)
        return;
    exe[n] = '\0';

    gchar *dir = g_path_get_dirname (exe);
    gchar *schemas = g_build_filename (dir, "..", "share", "glib-2.0", "schemas", NULL);
    gchar *compiled = g_build_filename (schemas, "gschemas.compiled", NULL);

    if (g_file_test (compiled, G_FILE_TEST_IS_REGULAR))
        g_setenv ("GSETTINGS_SCHEMA_DIR", schemas, FALSE);

    g_free (compiled);
    g_free (schemas);
    g_free (dir);
}

GSettings *
byk_prefs_try_open (void)
{
    GSettingsSchemaSource *source = g_settings_schema_source_get_default ();
    if (source == NULL)
        return NULL;

    GSettingsSchema *schema =
        g_settings_schema_source_lookup (source, BYK_PREFS_SCHEMA, TRUE);
    if (schema == NULL)
        return NULL;

    g_settings_schema_unref (schema);
    return g_settings_new (BYK_PREFS_SCHEMA);
}

gboolean
byk_prefs_boolean (GSettings *settings, const gchar *key, gboolean fallback)
{
    if (settings == NULL || key == NULL)
        return fallback;
    return g_settings_get_boolean (settings, key);
}
