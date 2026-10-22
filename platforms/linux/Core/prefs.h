/*
 * GSettings for the few prefs that actually change behaviour.
 *
 * The IBus engine, the Fcitx5 addon, and the GTK app are separate processes.
 * dconf is the Linux analogue of the macOS shared UserDefaults suite: flipping
 * a switch in Setup must reach the engine without a restart.
 *
 * g_settings_new aborts if the schema is missing, so every caller goes through
 * byk_prefs_try_open and treats NULL as "use the defaults".
 */
#ifndef BYAKARON_LINUX_PREFS_H
#define BYAKARON_LINUX_PREFS_H

#include <gio/gio.h>

G_BEGIN_DECLS

#define BYK_PREFS_SCHEMA                 "dev.nuhu.labs.Byakaron"
#define BYK_PREFS_PHONETIC_ONLY          "phonetic-only"
#define BYK_PREFS_CANDIDATES_HORIZONTAL  "candidates-horizontal"
#define BYK_PREFS_SPELLING_SUGGESTIONS   "spelling-suggestions"
#define BYK_PREFS_BANGLA_DIGITS          "bangla-digits"
#define BYK_PREFS_QT_CLICK_FIX           "qt-click-fix"
#define BYK_PREFS_LEARN_WORDS            "learn-words"

/* Point GSETTINGS_SCHEMA_DIR at the schemas next to an uninstalled binary. */
void byk_prefs_init_schema_dir (void);

/* NULL when the schema is not installed. Never aborts. */
GSettings *byk_prefs_try_open (void);

gboolean byk_prefs_boolean (GSettings *settings, const gchar *key, gboolean fallback);

G_END_DECLS

#endif /* BYAKARON_LINUX_PREFS_H */
