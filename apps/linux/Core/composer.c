#include "composer.h"

#include "autocomplete.h"
#include "corrector.h"
#include "transliterator.h"
#include "userdict.h"

/* X11 keysyms — IBus, GDK and Fcitx5 all speak these. */
#define BYK_KEY_BackSpace    0xff08
#define BYK_KEY_Return       0xff0d
#define BYK_KEY_Escape       0xff1b
#define BYK_KEY_space        0x0020
#define BYK_KEY_Page_Up      0xff55
#define BYK_KEY_Page_Down    0xff56
#define BYK_KEY_KP_Space     0xff80
#define BYK_KEY_KP_Enter     0xff8d
#define BYK_KEY_KP_Page_Up   0xff9a
#define BYK_KEY_KP_Page_Down 0xff9b
#define BYK_KEY_Left         0xff51
#define BYK_KEY_Up           0xff52
#define BYK_KEY_Right        0xff53
#define BYK_KEY_Down         0xff54
#define BYK_KEY_KP_Left      0xff96
#define BYK_KEY_KP_Up        0xff97
#define BYK_KEY_KP_Right     0xff98
#define BYK_KEY_KP_Down      0xff99
#define BYK_KEY_0            0x0030
#define BYK_KEY_9            0x0039
#define BYK_KEY_KP_0         0xffb0
#define BYK_KEY_KP_9         0xffb9
#define BYK_KEY_KP_1         0xffb1
#define BYK_KEY_Scroll_Lock  0xff14
#define BYK_KEY_Mode_switch  0xff7e
#define BYK_KEY_Num_Lock     0xff7f
#define BYK_KEY_Shift_L      0xffe1
#define BYK_KEY_Hyper_R      0xffee
#define BYK_KEY_ISO_Level3_Shift 0xfe03
#define BYK_KEY_ISO_Level5_Shift 0xfe11

struct _BykComposer {
    GString *latin;
    BykTransliterator *transliterator;
    BykAutoComplete *autocomplete;
    gchar **candidates; /* NULL-terminated, or NULL when hidden */
    guint page;
    gint cursor;        /* highlighted candidate (whole list), or -1 for none */
    gboolean phonetic_only;
    BykCorrector *corrector; /* borrowed; NULL = no spelling corrections */
    gboolean corrections;    /* the "spelling suggestions" setting */
    BykUserDict *userdict;   /* borrowed; the personal dictionary, or NULL */
    gboolean bangla_digits;  /* the "Bangla digits" setting */
};

static BykOutcome
byk_outcome (BykAction action, gchar *commit, gboolean pass_key)
{
    BykOutcome o = { .action = action, .commit = commit, .pass_key = pass_key };
    return o;
}

static void
byk_composer_drop_candidates (BykComposer *self)
{
    g_clear_pointer (&self->candidates, g_strfreev);
    self->page = 0;
    self->cursor = -1;
}

static void
byk_composer_refill_candidates (BykComposer *self, const gchar *bangla)
{
    byk_composer_drop_candidates (self);

    if (self->phonetic_only)
        return;

    if (self->autocomplete == NULL || bangla == NULL || *bangla == '\0')
        return;

    gchar **words = byk_autocomplete_prefix (self->autocomplete, bangla,
                                             BYK_COMPOSER_CANDIDATE_LIMIT);
    /* Words the user saved that start with this. They go right after the
     * first entry (the typed word when it is in the dictionary), ahead of the
     * dictionary's other completions: the user chose them. */
    gchar **mine = self->userdict != NULL
        ? byk_userdict_prefix (self->userdict, bangla, 5) : NULL;

    if ((words != NULL && words[0] != NULL) || (mine != NULL && mine[0] != NULL)) {
        GPtrArray *list = g_ptr_array_new ();
        GHashTable *seen = g_hash_table_new (g_str_hash, g_str_equal);
        const gboolean from_lexicon = words != NULL && words[0] != NULL;
        const gchar *first = from_lexicon ? words[0] : bangla;
#define BYK_LIST_ADD(w) \
        G_STMT_START { \
            if (list->len < BYK_COMPOSER_CANDIDATE_LIMIT && g_hash_table_add (seen, (gpointer) (w))) \
                g_ptr_array_add (list, g_strdup (w)); \
        } G_STMT_END
        BYK_LIST_ADD (first);
        for (guint i = 0; mine != NULL && mine[i] != NULL; i++)
            BYK_LIST_ADD (mine[i]);
        for (guint i = 1; words != NULL && words[0] != NULL && words[i] != NULL; i++)
            BYK_LIST_ADD (words[i]);
#undef BYK_LIST_ADD
        g_hash_table_destroy (seen);
        g_strfreev (words);
        g_strfreev (mine);

        /* A saved word that is exactly what was typed, alone, is not a list
         * worth showing (a dictionary hit alone still is, as before). */
        if (!from_lexicon && list->len == 1 && g_strcmp0 (g_ptr_array_index (list, 0), bangla) == 0) {
            g_ptr_array_free (list, TRUE);
            return;
        }
        g_ptr_array_add (list, NULL);
        self->candidates = (gchar **) g_ptr_array_free (list, FALSE);
        return;
    }
    g_strfreev (words);
    g_strfreev (mine);

    /* The user saved this exact word: it is not a misspelling. */
    if (self->userdict != NULL && byk_userdict_contains (self->userdict, bangla))
        return;

    /*
     * Nothing in the dictionary starts with this, so Avro probably spelled it
     * wrong (`sonar` → সনার). Offer the spell checker's corrections after the
     * typed word, which stays first so Space and 1 still mean "as typed".
     * Single letters are skipped: everything is a "misspelling" of them.
     */
    if (self->corrector == NULL || !self->corrections || g_utf8_strlen (bangla, -1) < 2)
        return;

    gchar **fixes = byk_corrector_get (self->corrector, bangla);
    if (fixes != NULL && fixes[0] != NULL) {
        GPtrArray *list = g_ptr_array_new ();
        g_ptr_array_add (list, g_strdup (bangla));
        for (guint i = 0; fixes[i] != NULL; i++)
            g_ptr_array_add (list, g_strdup (fixes[i]));
        g_ptr_array_add (list, NULL);
        self->candidates = (gchar **) g_ptr_array_free (list, FALSE);
    }
    g_strfreev (fixes);
}

static gchar *
byk_composer_bangla (BykComposer *self)
{
    if (self->latin->len == 0)
        return g_strdup ("");

    gchar *bangla = byk_transliterator_run (self->transliterator, self->latin->str);
    if (bangla == NULL)
        bangla = g_strdup (self->latin->str);
    return bangla;
}

static BykOutcome
byk_composer_commit_text (BykComposer *self, const gchar *suffix)
{
    gchar *final = NULL;

    if (self->latin->len == 0) {
        if (suffix != NULL && *suffix != '\0')
            final = g_strdup (suffix);
    } else {
        gchar *bangla = byk_composer_bangla (self);
        final = (suffix != NULL && *suffix != '\0')
            ? g_strconcat (bangla, suffix, NULL)
            : bangla;
        if (final != bangla)
            g_free (bangla);
    }

    g_string_truncate (self->latin, 0);
    byk_composer_drop_candidates (self);
    return byk_outcome (BYK_ACT_COMMIT, final, FALSE);
}

static BykOutcome
byk_composer_commit_at (BykComposer *self, guint pos)
{
    if (self->candidates == NULL || pos >= g_strv_length (self->candidates))
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    gchar *word = g_strdup (self->candidates[pos]);
    g_string_truncate (self->latin, 0);
    byk_composer_drop_candidates (self);
    return byk_outcome (BYK_ACT_COMMIT, word, FALSE);
}

static BykOutcome
byk_composer_commit_candidate (BykComposer *self, guint index)
{
    if (index >= BYK_COMPOSER_PAGE_SIZE)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
    return byk_composer_commit_at (self, self->page * BYK_COMPOSER_PAGE_SIZE + index);
}

/*
 * Arrow keys walk a highlight through the list: Down/Right forward, Up/Left
 * back, across pages. Nothing is highlighted until the first arrow, and Up
 * from the first candidate removes the highlight again, so Enter goes back to
 * meaning "the word as typed". Space never takes the highlight: it always
 * commits what was typed, as before.
 */
static BykOutcome
byk_composer_move_cursor (BykComposer *self, gboolean forward)
{
    const gint count = (gint) g_strv_length (self->candidates);

    if (forward)
        self->cursor = MIN (self->cursor + 1, count - 1);
    else
        self->cursor = MAX (self->cursor - 1, -1);

    if (self->cursor >= 0)
        self->page = (guint) self->cursor / BYK_COMPOSER_PAGE_SIZE;
    return byk_outcome (BYK_ACT_EAT, NULL, FALSE);
}

/*
 * Printable ASCII except space, plus keypad digits. Space commits; 1–9 pick a
 * candidate *before* this runs, so they are not stolen from the list.
 *
 * Probe of the Zig Avro engine (2026-09-09): `.` → `।`, `:` → `ঃ`, `$` → `৳`,
 * `^` → `ঁ`, `` ` `` is a kar, `,` `?` `!` stay ASCII. Buffering all of
 * 0x21–0x7e is what makes `ami.` preedit as আমি। instead of committing আমি
 * and typing a raw '.'.
 */
static inline gboolean
byk_is_bufferable_key (guint keyval)
{
    if (keyval >= BYK_KEY_KP_0 && keyval <= BYK_KEY_KP_9)
        return TRUE;
    return keyval >= 0x21 && keyval <= 0x7e;
}

static inline gchar
byk_latin_char (guint keyval)
{
    if (keyval >= BYK_KEY_KP_0 && keyval <= BYK_KEY_KP_9)
        return (gchar) ('0' + (keyval - BYK_KEY_KP_0));
    return (gchar) keyval;
}

/*
 * Shift / Caps / AltGr / NumLock produce no character. IBus and Fcitx5 still
 * send them as key events. The fallback below commits on any unknown key, so
 * treating Shift as "unknown" would commit `bhal` and then type `O` as a new
 * word: ভালও instead of ভালো. macOS never sees a bare Shift that way.
 */
static inline gboolean
byk_is_modifier_key (guint keyval)
{
    if (keyval >= BYK_KEY_Shift_L && keyval <= BYK_KEY_Hyper_R)
        return TRUE;
    switch (keyval) {
    case 0xfe01: /* ISO_Lock */
    case 0xfe02: /* ISO_Level2_Latch */
    case BYK_KEY_ISO_Level3_Shift:
    case 0xfe04: /* ISO_Level3_Latch */
    case 0xfe05: /* ISO_Level3_Lock */
    case 0xfe08: /* ISO_Group_Shift */
    case BYK_KEY_ISO_Level5_Shift:
    case 0xfe12: /* ISO_Level5_Latch */
    case 0xfe13: /* ISO_Level5_Lock */
    case BYK_KEY_Mode_switch:
    case BYK_KEY_Num_Lock:
    case BYK_KEY_Scroll_Lock:
        return TRUE;
    default:
        return FALSE;
    }
}

static inline gint
byk_candidate_index (guint keyval)
{
    if (keyval >= (BYK_KEY_0 + 1) && keyval <= BYK_KEY_9)
        return (gint) (keyval - (BYK_KEY_0 + 1));
    if (keyval >= BYK_KEY_KP_1 && keyval <= BYK_KEY_KP_9)
        return (gint) (keyval - BYK_KEY_KP_1);
    return -1;
}

BykComposer *
byk_composer_new (void)
{
    BykComposer *self = g_new0 (BykComposer, 1);
    self->cursor = -1;
    self->latin = g_string_sized_new (32);
    self->corrections = TRUE;
    self->bangla_digits = TRUE;
    self->transliterator = byk_transliterator_new ();
    self->autocomplete = byk_autocomplete_new ();

    if (self->transliterator == NULL)
        g_warning ("byakaron: transliterator unavailable, keys will pass through");
    if (self->autocomplete == NULL)
        g_warning ("byakaron: lexicon unavailable, candidates are disabled");

    return self;
}

void
byk_composer_free (BykComposer *self)
{
    if (self == NULL)
        return;
    g_clear_pointer (&self->transliterator, byk_transliterator_free);
    g_clear_pointer (&self->autocomplete, byk_autocomplete_free);
    byk_composer_drop_candidates (self);
    g_string_free (self->latin, TRUE);
    g_free (self);
}

gboolean
byk_composer_ready (BykComposer *self)
{
    return self != NULL && self->transliterator != NULL;
}

const gchar *
byk_composer_latin (BykComposer *self)
{
    g_return_val_if_fail (self != NULL, "");
    return self->latin->str;
}

gchar *
byk_composer_preedit (BykComposer *self)
{
    g_return_val_if_fail (self != NULL, g_strdup (""));
    return byk_composer_bangla (self);
}

gchar **
byk_composer_candidates (BykComposer *self)
{
    g_return_val_if_fail (self != NULL, NULL);
    return self->candidates;
}

gboolean
byk_composer_table_visible (BykComposer *self)
{
    return self != NULL && self->candidates != NULL;
}

guint
byk_composer_page (BykComposer *self)
{
    return self != NULL ? self->page : 0;
}

gint
byk_composer_cursor (BykComposer *self)
{
    return self != NULL && self->candidates != NULL ? self->cursor : -1;
}

BykOutcome
byk_composer_cursor_move (BykComposer *self, gboolean forward)
{
    g_return_val_if_fail (self != NULL, byk_outcome (BYK_ACT_PASS, NULL, FALSE));
    if (self->candidates == NULL)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
    return byk_composer_move_cursor (self, forward);
}

void
byk_composer_set_phonetic_only (BykComposer *self, gboolean phonetic_only)
{
    g_return_if_fail (self != NULL);

    phonetic_only = !!phonetic_only;
    if (self->phonetic_only == phonetic_only)
        return;

    self->phonetic_only = phonetic_only;

    if (self->latin->len == 0) {
        byk_composer_drop_candidates (self);
        return;
    }

    gchar *bangla = byk_composer_bangla (self);
    byk_composer_refill_candidates (self, bangla);
    g_free (bangla);
}

void
byk_composer_set_corrector (BykComposer *self, BykCorrector *corrector)
{
    g_return_if_fail (self != NULL);
    self->corrector = corrector;
}

void
byk_composer_set_bangla_digits (BykComposer *self, gboolean bangla)
{
    g_return_if_fail (self != NULL);
    self->bangla_digits = !!bangla;
}

void
byk_composer_set_userdict (BykComposer *self, BykUserDict *userdict)
{
    g_return_if_fail (self != NULL);
    self->userdict = userdict;
}

void
byk_composer_set_corrections (BykComposer *self, gboolean enabled)
{
    g_return_if_fail (self != NULL);
    if (self->corrections == !!enabled)
        return;
    self->corrections = !!enabled;
    byk_composer_refresh (self);
}

void
byk_composer_refresh (BykComposer *self)
{
    g_return_if_fail (self != NULL);
    if (self->latin->len == 0)
        return;
    gchar *bangla = byk_composer_bangla (self);
    byk_composer_refill_candidates (self, bangla);
    g_free (bangla);
}

gboolean
byk_composer_phonetic_only (BykComposer *self)
{
    return self != NULL && self->phonetic_only;
}

BykOutcome
byk_composer_select (BykComposer *self, guint index)
{
    g_return_val_if_fail (self != NULL, byk_outcome (BYK_ACT_PASS, NULL, FALSE));
    return byk_composer_commit_candidate (self, index);
}

BykOutcome
byk_composer_page_delta (BykComposer *self, gboolean down)
{
    g_return_val_if_fail (self != NULL, byk_outcome (BYK_ACT_PASS, NULL, FALSE));

    if (self->candidates == NULL)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    const guint count = g_strv_length (self->candidates);
    const guint pages = (count + BYK_COMPOSER_PAGE_SIZE - 1) / BYK_COMPOSER_PAGE_SIZE;
    if (pages == 0)
        return byk_outcome (BYK_ACT_EAT, NULL, FALSE);

    if (down && self->page + 1 < pages)
        self->page++;
    else if (!down && self->page > 0)
        self->page--;

    /* A highlight follows the page, onto its first candidate. */
    if (self->cursor >= 0)
        self->cursor = (gint) (self->page * BYK_COMPOSER_PAGE_SIZE);

    /* Eat even at the end of the list: Page Down must not scroll the document
     * underneath a candidate list the user is reading through. */
    return byk_outcome (BYK_ACT_EAT, NULL, FALSE);
}

BykOutcome
byk_composer_flush (BykComposer *self)
{
    g_return_val_if_fail (self != NULL, byk_outcome (BYK_ACT_PASS, NULL, FALSE));
    if (self->latin->len == 0)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
    return byk_composer_commit_text (self, NULL);
}

BykOutcome
byk_composer_key (BykComposer *self, guint keyval, guint mods)
{
    g_return_val_if_fail (self != NULL, byk_outcome (BYK_ACT_PASS, NULL, FALSE));

    if (mods & BYK_MOD_RELEASE)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    if (self->transliterator == NULL)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    if (byk_is_modifier_key (keyval))
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    if (mods & BYK_MOD_SHORTCUT) {
        BykOutcome o = byk_composer_flush (self);
        o.pass_key = TRUE;
        if (o.action == BYK_ACT_PASS)
            return o;
        o.action = BYK_ACT_COMMIT;
        return o;
    }

    const gboolean has_preedit = self->latin->len > 0;

    switch (keyval) {
    case BYK_KEY_BackSpace:
        if (!has_preedit)
            return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
        g_string_truncate (self->latin, self->latin->len - 1);
        {
            gchar *bangla = byk_composer_bangla (self);
            byk_composer_refill_candidates (self, bangla);
            g_free (bangla);
        }
        return byk_outcome (BYK_ACT_EAT, NULL, FALSE);

    case BYK_KEY_Escape:
        if (!has_preedit)
            return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
        g_string_truncate (self->latin, 0);
        byk_composer_drop_candidates (self);
        return byk_outcome (BYK_ACT_EAT, NULL, FALSE);

    case BYK_KEY_space:
    case BYK_KEY_KP_Space:
        if (!has_preedit)
            return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
        return byk_composer_commit_text (self, " ");

    case BYK_KEY_Return:
    case BYK_KEY_KP_Enter:
        if (!has_preedit)
            return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
        /* A highlighted candidate is what Enter picks; the Enter itself is
         * consumed, the same as picking it with its number key. */
        if (self->candidates != NULL && self->cursor >= 0)
            return byk_composer_commit_at (self, (guint) self->cursor);
        {
            BykOutcome o = byk_composer_commit_text (self, NULL);
            o.pass_key = TRUE;
            return o;
        }

    case BYK_KEY_Down:
    case BYK_KEY_KP_Down:
    case BYK_KEY_Right:
    case BYK_KEY_KP_Right:
    case BYK_KEY_Up:
    case BYK_KEY_KP_Up:
    case BYK_KEY_Left:
    case BYK_KEY_KP_Left:
        /* Without a list the arrows keep their usual meaning: commit the word
         * and let the app move the caret (the fallback below). */
        if (self->candidates != NULL)
            return byk_composer_move_cursor (self,
                keyval == BYK_KEY_Down || keyval == BYK_KEY_KP_Down ||
                keyval == BYK_KEY_Right || keyval == BYK_KEY_KP_Right);
        break;

    case BYK_KEY_Page_Down:
    case BYK_KEY_KP_Page_Down:
        return byk_composer_page_delta (self, TRUE);

    case BYK_KEY_Page_Up:
    case BYK_KEY_KP_Page_Up:
        return byk_composer_page_delta (self, FALSE);

    default:
        break;
    }

    const gint candidate = byk_candidate_index (keyval);
    if (candidate >= 0) {
        BykOutcome picked = byk_composer_commit_candidate (self, (guint) candidate);
        if (picked.action == BYK_ACT_COMMIT)
            return picked;
    }

    /* With Bangla digits off, a digit is not part of the word: the fallback
     * below commits the word and lets the application type the 0-9. */
    const gboolean digit = (keyval >= BYK_KEY_0 && keyval <= BYK_KEY_9) ||
                           (keyval >= BYK_KEY_KP_0 && keyval <= BYK_KEY_KP_9);
    if (byk_is_bufferable_key (keyval) && !(digit && !self->bangla_digits)) {
        g_string_append_c (self->latin, byk_latin_char (keyval));
        gchar *bangla = byk_composer_bangla (self);
        byk_composer_refill_candidates (self, bangla);
        g_free (bangla);
        return byk_outcome (BYK_ACT_EAT, NULL, FALSE);
    }

    if (has_preedit) {
        BykOutcome o = byk_composer_commit_text (self, NULL);
        o.pass_key = TRUE;
        return o;
    }
    return byk_outcome (BYK_ACT_PASS, NULL, FALSE);
}
