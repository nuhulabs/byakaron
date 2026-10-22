/*
 * GSettings, now only for what is Linux-specific: the IBus "Qt click fix".
 *
 * The keyboard settings every platform shares live in settings.json, through
 * the composer (Core/composer.h). The old keys below stay in the schema only
 * so composer.c can carry their values into settings.json once.
 *
 * g_settings_new aborts if the schema is missing, so every caller goes through
 * byk_prefs_try_open and treats NULL as "use the defaults".
 */
#ifndef BYAKARON_LINUX_PREFS_H
#define BYAKARON_LINUX_PREFS_H

#include <gio/gio.h>

G_BEGIN_DECLS

#define BYK_PREFS_SCHEMA                 "dev.nuhu.labs.Byakaron"
#define BYK_PREFS_QT_CLICK_FIX           "qt-click-fix"

/* Deprecated: read once to migrate into settings.json. */
#define BYK_PREFS_OLD_PHONETIC_ONLY          "phonetic-only"
#define BYK_PREFS_OLD_CANDIDATES_HORIZONTAL  "candidates-horizontal"
#define BYK_PREFS_OLD_SPELLING_SUGGESTIONS   "spelling-suggestions"
#define BYK_PREFS_OLD_BANGLA_DIGITS          "bangla-digits"

/* Point GSETTINGS_SCHEMA_DIR at the schemas next to an uninstalled binary. */
void byk_prefs_init_schema_dir (void);

/* NULL when the schema is not installed. Never aborts. */
GSettings *byk_prefs_try_open (void);

gboolean byk_prefs_boolean (GSettings *settings, const gchar *key, gboolean fallback);

G_END_DECLS

#endif /* BYAKARON_LINUX_PREFS_H */
