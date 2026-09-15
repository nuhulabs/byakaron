#include "composer.h"

#include "autocomplete.h"
#include "transliterator.h"

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
    gboolean phonetic_only;
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
    if (words == NULL)
        return;
    if (words[0] == NULL) {
        g_strfreev (words);
        return;
    }
    self->candidates = words;
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
byk_composer_commit_candidate (BykComposer *self, guint index)
{
    if (self->candidates == NULL)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    const guint pos = self->page * BYK_COMPOSER_PAGE_SIZE + index;
    if (self->candidates[pos] == NULL)
        return byk_outcome (BYK_ACT_PASS, NULL, FALSE);

    gchar *word = g_strdup (self->candidates[pos]);
    g_string_truncate (self->latin, 0);
    byk_composer_drop_candidates (self);
    return byk_outcome (BYK_ACT_COMMIT, word, FALSE);
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
    self->latin = g_string_sized_new (32);
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
        {
            BykOutcome o = byk_composer_commit_text (self, NULL);
            o.pass_key = TRUE;
            return o;
        }

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

    if (byk_is_bufferable_key (keyval)) {
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
