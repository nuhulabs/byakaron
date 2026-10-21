/*
 * The personal dictionary: words the user has told Byakaron are correct.
 *
 * One word per line in $XDG_DATA_HOME/byakaron/user-words.txt (normally
 * ~/.local/share/byakaron/), sorted, written atomically. The GTK app adds and
 * removes words; the input method only reads them, and picks up the app's
 * changes by re-reading the (small) file at most once a second, on a
 * keystroke, so neither needs the other running.
 *
 * Words are stored NFC-normalised so আমায় typed or pasted either way is one
 * entry. BYAKARON_USER_DICT overrides the path (tests).
 */
#ifndef BYAKARON_LINUX_USERDICT_H
#define BYAKARON_LINUX_USERDICT_H

#include <glib.h>

G_BEGIN_DECLS

typedef struct _BykUserDict BykUserDict;

/* Loads the file if it exists; a missing file is an empty dictionary. */
BykUserDict *byk_userdict_new (void);
void byk_userdict_free (BykUserDict *self);

const gchar *byk_userdict_path (BykUserDict *self);

gboolean byk_userdict_contains (BykUserDict *self, const gchar *word);

/* Saved words starting with `prefix`, sorted, at most `limit`. Never NULL;
 * g_strfreev. An exact match is included. */
gchar **byk_userdict_prefix (BykUserDict *self, const gchar *prefix, guint limit);

/* All words, sorted. g_strfreev. */
gchar **byk_userdict_words (BykUserDict *self);
guint byk_userdict_count (BykUserDict *self);

/* Add / remove and save immediately. FALSE with `error` set if the file could
 * not be written (the in-memory list is left unchanged then). Adding a word
 * that is already there, or removing one that is not, succeeds. */
gboolean byk_userdict_add (BykUserDict *self, const gchar *word, GError **error);
gboolean byk_userdict_remove (BykUserDict *self, const gchar *word, GError **error);

/* Re-read the file if another process changed it. At most once per second;
 * the file is a few KB. Returns TRUE if the words changed. */
gboolean byk_userdict_reload_if_changed (BykUserDict *self);

G_END_DECLS

#endif /* BYAKARON_LINUX_USERDICT_H */
