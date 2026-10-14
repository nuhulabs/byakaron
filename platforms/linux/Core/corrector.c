#include "corrector.h"

#include "spell.h"

/* Typing produces a new word per keystroke; a few hundred is plenty and keeps
 * memory flat over a long session. */
#define BYK_CORRECTOR_CACHE_MAX 512

typedef struct {
    GMutex lock;
    GHashTable *cache;   /* word -> gchar ** (owned) */
    GHashTable *pending; /* word -> itself, queued on the worker */
    BykSpell *spell;     /* used by one thread only: the worker, or the caller */
    GThreadPool *pool;   /* NULL in inline mode */
    GMainContext *context;
    BykCorrectorReady ready;
    gpointer ready_data;
    gboolean closed;
} BykCorrectorState;

/* The handle is a reference: the worker and queued callbacks hold their own,
 * so freeing the corrector while a lookup is in flight is safe. */
struct _BykCorrector {
    BykCorrectorState *state;
};

static void
byk_corrector_state_clear (gpointer data)
{
    BykCorrectorState *st = data;
    g_clear_pointer (&st->cache, g_hash_table_destroy);
    g_clear_pointer (&st->pending, g_hash_table_destroy);
    g_clear_pointer (&st->spell, byk_spell_free);
    g_clear_pointer (&st->context, g_main_context_unref);
    g_mutex_clear (&st->lock);
}

/* Look `word` up. Runs on whichever single thread owns `st->spell`. */
static gchar **
byk_corrector_compute (BykCorrectorState *st, const gchar *word)
{
    if (byk_spell_is_correct (st->spell, word) != 0)
        return g_new0 (gchar *, 1);

    gchar **found = byk_spell_suggest (st->spell, word, BYK_CORRECTOR_LIMIT + 1);
    GPtrArray *out = g_ptr_array_new ();
    for (guint i = 0; found != NULL && found[i] != NULL && out->len < BYK_CORRECTOR_LIMIT; i++)
        if (g_strcmp0 (found[i], word) != 0)
            g_ptr_array_add (out, g_strdup (found[i]));
    g_ptr_array_add (out, NULL);
    g_strfreev (found);
    return (gchar **) g_ptr_array_free (out, FALSE);
}

static void
byk_corrector_store (BykCorrectorState *st, const gchar *word, gchar **fixes)
{
    if (g_hash_table_size (st->cache) >= BYK_CORRECTOR_CACHE_MAX)
        g_hash_table_remove_all (st->cache);
    g_hash_table_insert (st->cache, g_strdup (word), fixes);
}

typedef struct {
    BykCorrectorState *st; /* reference */
    gchar *word;
} BykReadyCall;

static gboolean
byk_corrector_dispatch_ready (gpointer data)
{
    BykReadyCall *call = data;
    BykCorrectorReady ready;
    gpointer ready_data;

    g_mutex_lock (&call->st->lock);
    ready = call->st->closed ? NULL : call->st->ready;
    ready_data = call->st->ready_data;
    g_mutex_unlock (&call->st->lock);

    if (ready != NULL)
        ready (call->word, ready_data);

    g_rc_box_release_full (call->st, byk_corrector_state_clear);
    g_free (call->word);
    g_free (call);
    return G_SOURCE_REMOVE;
}

static void
byk_corrector_worker (gpointer job, gpointer user_data)
{
    gchar *word = job;
    BykCorrectorState *st = user_data;

    g_mutex_lock (&st->lock);
    const gboolean closed = st->closed;
    g_mutex_unlock (&st->lock);

    if (!closed) {
        gchar **fixes = byk_corrector_compute (st, word);

        g_mutex_lock (&st->lock);
        byk_corrector_store (st, word, fixes);
        g_hash_table_remove (st->pending, word);
        g_mutex_unlock (&st->lock);

        BykReadyCall *call = g_new0 (BykReadyCall, 1);
        call->st = g_rc_box_acquire (st);
        call->word = g_strdup (word);
        g_main_context_invoke (st->context, byk_corrector_dispatch_ready, call);
    }
    g_free (word);
}

BykCorrector *
byk_corrector_new (gboolean threaded, BykCorrectorReady ready, gpointer user_data)
{
    BykSpell *spell = byk_spell_new (NULL);
    if (spell == NULL)
        return NULL;

    BykCorrectorState *st = g_rc_box_new0 (BykCorrectorState);
    g_mutex_init (&st->lock);
    st->cache = g_hash_table_new_full (g_str_hash, g_str_equal, g_free,
                                       (GDestroyNotify) g_strfreev);
    st->pending = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    st->spell = spell;
    st->context = g_main_context_ref_thread_default ();
    st->ready = ready;
    st->ready_data = user_data;

    if (threaded) {
        /* One thread: lookups are serialised on the one BykSpell it owns. */
        st->pool = g_thread_pool_new (byk_corrector_worker, st, 1, FALSE, NULL);
    }

    BykCorrector *self = g_new0 (BykCorrector, 1);
    self->state = st;
    return self;
}

void
byk_corrector_free (BykCorrector *self)
{
    if (self == NULL)
        return;

    BykCorrectorState *st = self->state;
    g_mutex_lock (&st->lock);
    st->closed = TRUE;
    st->ready = NULL;
    g_mutex_unlock (&st->lock);

    /* Let the worker drain the queue: with `closed` set each queued word is
     * just freed, no lookup. (Dropping them instead would leak the strings:
     * GLib 2.64 on Ubuntu 20.04 has no item-free hook for thread pools.) The
     * pool is gone before the state is released, so the worker never needs
     * its own reference. */
    if (st->pool != NULL)
        g_thread_pool_free (st->pool, FALSE, TRUE);
    st->pool = NULL;

    g_rc_box_release_full (st, byk_corrector_state_clear);
    g_free (self);
}

gchar **
byk_corrector_get (BykCorrector *self, const gchar *word)
{
    g_return_val_if_fail (self != NULL && word != NULL, NULL);
    BykCorrectorState *st = self->state;

    g_mutex_lock (&st->lock);
    gchar **cached = g_hash_table_lookup (st->cache, word);
    if (cached != NULL) {
        gchar **copy = g_strdupv (cached);
        g_mutex_unlock (&st->lock);
        return copy;
    }

    if (st->pool == NULL) {
        g_mutex_unlock (&st->lock);
        gchar **fixes = byk_corrector_compute (st, word);
        g_mutex_lock (&st->lock);
        byk_corrector_store (st, word, g_strdupv (fixes));
        g_mutex_unlock (&st->lock);
        return fixes;
    }

    if (!g_hash_table_contains (st->pending, word)) {
        g_hash_table_add (st->pending, g_strdup (word));
        g_thread_pool_push (st->pool, g_strdup (word), NULL);
    }
    g_mutex_unlock (&st->lock);
    return NULL;
}
