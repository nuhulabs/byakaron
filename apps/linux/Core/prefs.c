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

/* g_settings_get_boolean aborts on a key the installed schema does not have. */
gboolean
byk_prefs_has_key (GSettings *settings, const gchar *key)
{
    GSettingsSchema *schema = NULL;

    if (settings == NULL || key == NULL)
        return FALSE;

    g_object_get (settings, "settings-schema", &schema, NULL);
    const gboolean found = schema != NULL && g_settings_schema_has_key (schema, key);
    g_clear_pointer (&schema, g_settings_schema_unref);
    return found;
}

gboolean
byk_prefs_boolean (GSettings *settings, const gchar *key, gboolean fallback)
{
    return byk_prefs_has_key (settings, key) ? g_settings_get_boolean (settings, key)
                                             : fallback;
}

void
byk_prefs_set_boolean (GSettings *settings, const gchar *key, gboolean value)
{
    if (byk_prefs_has_key (settings, key))
        g_settings_set_boolean (settings, key, value);
}

gint64
byk_prefs_int64 (GSettings *settings, const gchar *key, gint64 fallback)
{
    return byk_prefs_has_key (settings, key) ? g_settings_get_int64 (settings, key) : fallback;
}

void
byk_prefs_set_int64 (GSettings *settings, const gchar *key, gint64 value)
{
    if (byk_prefs_has_key (settings, key))
        g_settings_set_int64 (settings, key, value);
}

static void
byk_prefs_add_panel_extension (void)
{
    /* Two because GNOME 45 changed what extension.js is; Shell runs the one
     * that lists its version and skips the other. */
    static const gchar *const uuids[] = {
        "byakaron-panel@nuhulabs.com", "byakaron-panel-legacy@nuhulabs.com", NULL
    };
    GSettings *shell = g_settings_new ("org.gnome.shell");
    gchar **enabled = g_settings_get_strv (shell, "enabled-extensions");
    GPtrArray *wanted = g_ptr_array_new ();

    for (gchar **uuid = enabled; *uuid != NULL; uuid++)
        g_ptr_array_add (wanted, *uuid);
    for (guint i = 0; uuids[i] != NULL; i++)
        if (!g_strv_contains ((const gchar *const *) enabled, uuids[i]))
            g_ptr_array_add (wanted, (gpointer) uuids[i]);
    g_ptr_array_add (wanted, NULL);

    g_settings_set_strv (shell, "enabled-extensions",
                         (const gchar *const *) wanted->pdata);
    g_ptr_array_free (wanted, TRUE);
    g_strfreev (enabled);
    g_object_unref (shell);
}

void
byk_prefs_enable_panel_extension (void)
{
    GSettings *prefs = byk_prefs_try_open ();
    GSettingsSchemaSource *source = g_settings_schema_source_get_default ();
    GSettingsSchema *shell = source != NULL
        ? g_settings_schema_source_lookup (source, "org.gnome.shell", TRUE)
        : NULL;

    /* TRUE as the fallback: with no way to remember, do not ask every start. */
    if (shell != NULL && !byk_prefs_boolean (prefs, BYK_PREFS_PANEL_ENABLED, TRUE)) {
        byk_prefs_add_panel_extension ();
        byk_prefs_set_boolean (prefs, BYK_PREFS_PANEL_ENABLED, TRUE);
        g_settings_sync ();
    }

    g_clear_pointer (&shell, g_settings_schema_unref);
    g_clear_object (&prefs);
}
