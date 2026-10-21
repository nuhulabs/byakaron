/*
 * Spelling corrections for the keyboard's candidate list.
 *
 * When Avro turns what was typed into a word the dictionary does not know
 * (`sonar` → সনার), the prefix list is empty and the user had nothing to pick.
 * This offers the spell checker's corrections instead (সোনার).
 *
 * A correction lookup costs 0.2–10 ms warm and up to ~150 ms on a cold disk
 * cache, too slow for the keystroke path. So in threaded mode the lookup runs
 * on one worker thread with its own spell.db connection, results are cached,
 * and `ready` fires on the creating thread's main context when a word's
 * corrections arrive. The IBus engine re-asks then. Fcitx5 has no GLib main
 * loop, so it uses inline mode: the lookup runs on the calling thread, still
 * cached.
 *
 * Only this object touches its BykSpell, from one thread at a time.
 */
#ifndef BYAKARON_LINUX_CORRECTOR_H
#define BYAKARON_LINUX_CORRECTOR_H

#include <glib.h>

G_BEGIN_DECLS

#define BYK_CORRECTOR_LIMIT 3

typedef struct _BykCorrector BykCorrector;

/* Called on the creating thread's main context with the word whose corrections
 * are now cached. */
typedef void (*BykCorrectorReady) (const gchar *word, gpointer user_data);

/*
 * NULL when spell.db cannot be opened: no corrections, typing unaffected.
 * `threaded` FALSE = inline lookups (no main loop needed); `ready` is unused.
 */
BykCorrector *byk_corrector_new (gboolean threaded, BykCorrectorReady ready, gpointer user_data);

/* Stops the worker (waiting for a lookup in flight) and drops the callback. */
void byk_corrector_free (BykCorrector *self);

/*
 * Corrections for `word`, best first, never including `word` itself: an empty
 * array when it is spelled correctly or nothing is close. NULL in threaded
 * mode while the lookup is still running (it has been queued; `ready` follows).
 * Caller frees with g_strfreev.
 */
gchar **byk_corrector_get (BykCorrector *self, const gchar *word);

G_END_DECLS

#endif /* BYAKARON_LINUX_CORRECTOR_H */
