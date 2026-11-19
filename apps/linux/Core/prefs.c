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

/* Two because GNOME 45 changed what extension.js is; Shell runs the one that
 * lists its version and skips the other. */
static const gchar *const byk_panel_uuids[] = {
    "panel@byakaron.com", "panel-legacy@byakaron.com", NULL
};
/* What they were called up to 0.1.x: the package no longer ships them. */
static const gchar *const byk_old_panel_uuids[] = {
    "byakaron-panel@byakaron.com", "byakaron-panel-legacy@byakaron.com", NULL
};

static gboolean
byk_prefs_has_old_panel (gchar **enabled)
{
    for (guint i = 0; byk_old_panel_uuids[i] != NULL; i++)
        if (g_strv_contains ((const gchar *const *) enabled, byk_old_panel_uuids[i]))
            return TRUE;
    return FALSE;
}

/* The user's list without the old names, plus the panel's current ones. Every
 * other extension stays where it was. */
static void
byk_prefs_add_panel_extension (GSettings *shell, gchar **enabled)
{
    GPtrArray *wanted = g_ptr_array_new ();

    for (gchar **uuid = enabled; *uuid != NULL; uuid++)
        if (!g_strv_contains (byk_old_panel_uuids, *uuid))
            g_ptr_array_add (wanted, *uuid);
    for (guint i = 0; byk_panel_uuids[i] != NULL; i++)
        if (!g_strv_contains ((const gchar *const *) enabled, byk_panel_uuids[i]))
            g_ptr_array_add (wanted, (gpointer) byk_panel_uuids[i]);
    g_ptr_array_add (wanted, NULL);

    g_settings_set_strv (shell, "enabled-extensions",
                         (const gchar *const *) wanted->pdata);
    g_ptr_array_free (wanted, TRUE);
}

void
byk_prefs_enable_panel_extension (void)
{
    GSettings *prefs = byk_prefs_try_open ();
    GSettingsSchemaSource *source = g_settings_schema_source_get_default ();
    GSettingsSchema *schema = source != NULL
        ? g_settings_schema_source_lookup (source, "org.gnome.shell", TRUE)
        : NULL;

    if (schema != NULL) {
        GSettings *shell = g_settings_new ("org.gnome.shell");
        gchar **enabled = g_settings_get_strv (shell, "enabled-extensions");

        /* TRUE as the fallback: with no way to remember, do not ask every
         * start. A user who had the panel under its old name gets the new one,
         * whatever the flag says. */
        if (!byk_prefs_boolean (prefs, BYK_PREFS_PANEL_ENABLED, TRUE) ||
            byk_prefs_has_old_panel (enabled)) {
            byk_prefs_add_panel_extension (shell, enabled);
            byk_prefs_set_boolean (prefs, BYK_PREFS_PANEL_ENABLED, TRUE);
            g_settings_sync ();
        }
        g_strfreev (enabled);
        g_object_unref (shell);
    }

    g_clear_pointer (&schema, g_settings_schema_unref);
    g_clear_object (&prefs);
}
