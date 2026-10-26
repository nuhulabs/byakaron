/*
 * Thin GLib-friendly wrapper around libbyakaron's spell-check ABI.
 *
 * Byakaron.db is a local SQLite file shipped with the install, not a server.
 * Callers get g_malloc'd strings / gchar ** (g_strfreev), so the Zig ownership
 * rule stops here — same deal as composer.h.
 *
 * Used by App/ (the Spelling page); the keyboards only need byk_spell_locate_db.
 */
#ifndef BYAKARON_LINUX_SPELL_H
#define BYAKARON_LINUX_SPELL_H

#include <glib.h>

G_BEGIN_DECLS

#define BYK_SPELL_DB_SYSTEM "/usr/share/byakaron/Byakaron.db"

typedef struct _BykSpell BykSpell;

/*
 * Path of the Byakaron.db this process should open.
 *
 * Order: BYAKARON_SPELL_DB (dev / tests), then the system install path.
 * Returns a newly allocated string the caller frees with g_free, or NULL if
 * neither exists. Does not open the file.
 */
gchar *byk_spell_locate_db (void);

/*
 * Open Byakaron.db. Tries byk_spell_locate_db unless `db_path` is non-NULL.
 * Returns NULL if the file is missing or the engine cannot open it.
 */
BykSpell *byk_spell_new (const gchar *db_path);

/* Release an instance from byk_spell_new. NULL is ignored. */
void byk_spell_free (BykSpell *self);

/*
 * 1 if `word` is in the lexicon, 0 if unknown, -1 on error.
 */
gint byk_spell_is_correct (BykSpell *self, const gchar *word);

/*
 * Ranked suggestions for a (presumed misspelled) Bangla word.
 *
 * Returns a NULL-terminated array the caller frees with g_strfreev. An empty
 * array means "no suggestions"; NULL means the lookup itself failed.
 */
gchar **byk_spell_suggest (BykSpell *self, const gchar *word, gint limit);

G_END_DECLS

#endif /* BYAKARON_LINUX_SPELL_H */
