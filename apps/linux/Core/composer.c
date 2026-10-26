#include "composer.h"

#include <stdlib.h>
#include <string.h>

#include "prefs.h"
#include "spell.h"

/* X11 keysyms — IBus, GDK and Fcitx5 all speak these. */
#define BYK_KEY_space        0x0020
#define BYK_KEY_ISO_Left_Tab 0xfe20
#define BYK_KEY_BackSpace    0xff08
#define BYK_KEY_Tab          0xff09
#define BYK_KEY_Return       0xff0d
#define BYK_KEY_Scroll_Lock  0xff14
#define BYK_KEY_Escape       0xff1b
#define BYK_KEY_Left         0xff51
#define BYK_KEY_Up           0xff52
#define BYK_KEY_Right        0xff53
#define BYK_KEY_Down         0xff54
#define BYK_KEY_Page_Up      0xff55
#define BYK_KEY_Page_Down    0xff56
#define BYK_KEY_Mode_switch  0xff7e
#define BYK_KEY_Num_Lock     0xff7f
#define BYK_KEY_KP_Space     0xff80
#define BYK_KEY_KP_Tab       0xff89
#define BYK_KEY_KP_Enter     0xff8d
#define BYK_KEY_KP_Left      0xff96
#define BYK_KEY_KP_Up        0xff97
#define BYK_KEY_KP_Right     0xff98
#define BYK_KEY_KP_Down      0xff99
#define BYK_KEY_KP_Page_Up   0xff9a
#define BYK_KEY_KP_Page_Down 0xff9b
#define BYK_KEY_KP_0         0xffb0
#define BYK_KEY_KP_9         0xffb9
#define BYK_KEY_Shift_L      0xffe1
#define BYK_KEY_Hyper_R      0xffee

gchar *
byk_data_dir (void)
{
    const gchar *env = g_getenv ("BYAKARON_DATA_DIR");
    if (env != NULL && *env != '\0')
        return g_strdup (env);
    return g_build_filename (g_get_user_data_dir (), "byakaron", NULL);
}

/*
 * Shift / Caps / AltGr / Num Lock produce no character, but IBus and Fcitx5
 * still send them as key events. The composer commits the word on any key it
 * does not know, so sending Shift would commit `bhal` and type the `O` as a
 * new word: ভালও instead of ভালো.
 */
static gboolean
byk_is_modifier_key (guint keyval)
{
    if (keyval >= BYK_KEY_Shift_L && keyval <= BYK_KEY_Hyper_R)
        return TRUE;
    if (keyval >= 0xfe01 && keyval <= 0xfe13) /* ISO_Lock … ISO_Level5_Lock */
        return TRUE;
    return keyval == BYK_KEY_Mode_switch || keyval == BYK_KEY_Num_Lock ||
           keyval == BYK_KEY_Scroll_Lock;
}

gboolean
byk_keysym_to_key (guint keyval, int *kind, unsigned int *ch)
{
    *ch = 0;
    if (byk_is_modifier_key (keyval))
        return FALSE;

    if (keyval >= 0x21 && keyval <= 0x7e) {
        *kind = BYAKARON_KEY_CHAR;
        *ch = keyval;
        return TRUE;
    }
    if (keyval >= BYK_KEY_KP_0 && keyval <= BYK_KEY_KP_9) {
        *kind = BYAKARON_KEY_CHAR;
        *ch = '0' + (keyval - BYK_KEY_KP_0);
        return TRUE;
    }

    switch (keyval) {
    case BYK_KEY_space:
    case BYK_KEY_KP_Space:     *kind = BYAKARON_KEY_SPACE; break;
    case BYK_KEY_Return:
    case BYK_KEY_KP_Enter:     *kind = BYAKARON_KEY_ENTER; break;
    case BYK_KEY_Tab:
    case BYK_KEY_KP_Tab:
    case BYK_KEY_ISO_Left_Tab: *kind = BYAKARON_KEY_TAB; break;
    case BYK_KEY_BackSpace:    *kind = BYAKARON_KEY_BACKSPACE; break;
    case BYK_KEY_Escape:       *kind = BYAKARON_KEY_ESCAPE; break;
    case BYK_KEY_Up:
    case BYK_KEY_KP_Up:        *kind = BYAKARON_KEY_UP; break;
    case BYK_KEY_Down:
    case BYK_KEY_KP_Down:      *kind = BYAKARON_KEY_DOWN; break;
    case BYK_KEY_Left:
    case BYK_KEY_KP_Left:      *kind = BYAKARON_KEY_LEFT; break;
    case BYK_KEY_Right:
    case BYK_KEY_KP_Right:     *kind = BYAKARON_KEY_RIGHT; break;
    case BYK_KEY_Page_Up:
    case BYK_KEY_KP_Page_Up:   *kind = BYAKARON_KEY_PAGE_UP; break;
    case BYK_KEY_Page_Down:
    case BYK_KEY_KP_Page_Down: *kind = BYAKARON_KEY_PAGE_DOWN; break;
    default:                   *kind = BYAKARON_KEY_OTHER; break;
    }
    return TRUE;
}

/* ── settings ────────────────────────────────────────────────────────────── */

void
byk_settings_defaults (BykSettings *out)
{
    /* Settings.zig's defaults. */
    out->suggestions = TRUE;
    out->spelling_corrections = TRUE;
    out->learn_choices = TRUE;
    out->bangla_digits = TRUE;
    out->newline_on_enter = FALSE;
    out->vertical = FALSE;
    out->candidates_per_page = 9;
}

/*
 * The value of top-level field `name` in the settings JSON, or NULL. The
 * producer is Settings.stringify: a flat object of booleans, one string and
 * numbers, so finding `"name"` and the colon after it is enough.
 */
static const gchar *
byk_json_field (const gchar *json, const gchar *name)
{
    gchar *needle = g_strdup_printf ("\"%s\"", name);
    const gchar *p = strstr (json, needle);
    if (p != NULL) {
        p += strlen (needle);
        while (g_ascii_isspace (*p))
            p++;
        if (*p == ':') {
            p++;
            while (g_ascii_isspace (*p))
                p++;
        } else {
            p = NULL;
        }
    }
    g_free (needle);
    return p;
}

static void
byk_json_bool (const gchar *json, const gchar *name, gboolean *value)
{
    const gchar *p = byk_json_field (json, name);
    if (p != NULL && strncmp (p, "true", 4) == 0)
        *value = TRUE;
    else if (p != NULL && strncmp (p, "false", 5) == 0)
        *value = FALSE;
}

void
byk_settings_load (ByakaronComposer *composer, BykSettings *out)
{
    byk_settings_defaults (out);
    char *json = composer != NULL ? byakaron_settings_get (composer) : NULL;
    if (json == NULL)
        return;

    byk_json_bool (json, "suggestions", &out->suggestions);
    byk_json_bool (json, "spelling_corrections", &out->spelling_corrections);
    byk_json_bool (json, "learn_choices", &out->learn_choices);
    byk_json_bool (json, "bangla_digits", &out->bangla_digits);
    byk_json_bool (json, "newline_on_enter", &out->newline_on_enter);
    const gchar *p = byk_json_field (json, "candidate_orientation");
    if (p != NULL)
        out->vertical = strncmp (p, "\"vertical\"", 10) == 0;
    p = byk_json_field (json, "candidates_per_page");
    if (p != NULL && g_ascii_isdigit (*p))
        out->candidates_per_page = CLAMP ((gint) strtol (p, NULL, 10), 3, 9);

    byakaron_string_free (json);
}

gboolean
byk_settings_save (ByakaronComposer *composer, const BykSettings *s)
{
#define B(v) ((v) ? "true" : "false")
    gchar *json = g_strdup_printf (
        "{\"suggestions\":%s,\"spelling_corrections\":%s,\"learn_choices\":%s,"
        "\"bangla_digits\":%s,\"newline_on_enter\":%s,"
        "\"candidate_orientation\":\"%s\",\"candidates_per_page\":%d}",
        B (s->suggestions), B (s->spelling_corrections), B (s->learn_choices),
        B (s->bangla_digits), B (s->newline_on_enter),
        s->vertical ? "vertical" : "horizontal", CLAMP (s->candidates_per_page, 3, 9));
#undef B
    const gboolean ok = byakaron_settings_set (composer, json) == 0;
    g_free (json);
    return ok;
}

/*
 * Before settings.json, the switches were GSettings keys (dconf). The first
 * composer to start after the upgrade — the keyboard or the app — carries
 * them over once; the keys stay in the schema only so they can still be read
 * here. Users who never changed one get the same defaults either way.
 */
static void
byk_settings_migrate (ByakaronComposer *composer)
{
    BykSettings s;
    byk_settings_defaults (&s);

    GSettings *prefs = byk_prefs_try_open ();
    if (prefs != NULL) {
        s.suggestions = !byk_prefs_boolean (prefs, BYK_PREFS_OLD_PHONETIC_ONLY, FALSE);
        s.spelling_corrections = byk_prefs_boolean (prefs, BYK_PREFS_OLD_SPELLING_SUGGESTIONS, TRUE);
        s.bangla_digits = byk_prefs_boolean (prefs, BYK_PREFS_OLD_BANGLA_DIGITS, TRUE);
        s.vertical = !byk_prefs_boolean (prefs, BYK_PREFS_OLD_CANDIDATES_HORIZONTAL, TRUE);
        g_object_unref (prefs);
    }
    if (!byk_settings_save (composer, &s))
        g_warning ("byakaron: could not write settings.json");
}

ByakaronComposer *
byk_composer_open (gboolean with_spell, ByakaronUpdateFn on_update, gpointer userdata)
{
    gchar *dir = byk_data_dir ();
    gchar *settings = g_build_filename (dir, "settings.json", NULL);
    const gboolean fresh = !g_file_test (settings, G_FILE_TEST_EXISTS);
    gchar *spell = with_spell ? byk_spell_locate_db () : NULL;
    if (with_spell && spell == NULL)
        g_message ("byakaron: Byakaron.db unavailable, no spelling corrections");

    ByakaronComposer *composer = byakaron_composer_create (dir, spell, on_update, userdata);
    if (composer == NULL)
        g_warning ("byakaron: could not create the composer on %s", dir);
    else if (fresh)
        byk_settings_migrate (composer);

    g_free (spell);
    g_free (settings);
    g_free (dir);
    return composer;
}

/* ── word lists ──────────────────────────────────────────────────────────── */

static const gchar *
skip_ws (const gchar *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
        p++;
    return p;
}

static gint
hex4 (const gchar *p)
{
    gint v = 0;
    for (gint i = 0; i < 4; i++) {
        const gint d = g_ascii_xdigit_value (p[i]);
        if (d < 0)
            return -1;
        v = v * 16 + d;
    }
    return v;
}

/* One JSON string at the opening quote into `out`; returns the position past
 * the closing quote, or NULL if it is malformed. */
static const gchar *
parse_string (const gchar *p, GString *out)
{
    if (*p != '"')
        return NULL;
    p++;

    g_string_truncate (out, 0);
    while (*p != '"') {
        if (*p == '\0')
            return NULL;
        if (*p != '\\') {
            g_string_append_c (out, *p++);
            continue;
        }
        p++;
        switch (*p) {
        case '"':  g_string_append_c (out, '"');  break;
        case '\\': g_string_append_c (out, '\\'); break;
        case '/':  g_string_append_c (out, '/');  break;
        case 'b':  g_string_append_c (out, '\b'); break;
        case 'f':  g_string_append_c (out, '\f'); break;
        case 'n':  g_string_append_c (out, '\n'); break;
        case 'r':  g_string_append_c (out, '\r'); break;
        case 't':  g_string_append_c (out, '\t'); break;
        case 'u': {
            gint c = hex4 (p + 1);
            if (c < 0)
                return NULL;
            p += 4;
            if (c >= 0xd800 && c <= 0xdbff) { /* surrogate pair */
                const gint lo = p[1] == '\\' && p[2] == 'u' ? hex4 (p + 3) : -1;
                if (lo < 0xdc00 || lo > 0xdfff)
                    return NULL;
                c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
                p += 6;
            }
            g_string_append_unichar (out, (gunichar) c);
            break;
        }
        default:
            return NULL;
        }
        p++;
    }
    return p + 1;
}

gchar **
byk_parse_json_strings (const gchar *json)
{
    g_return_val_if_fail (json != NULL, NULL);

    const gchar *p = skip_ws (json);
    if (*p != '[')
        return NULL;
    p = skip_ws (p + 1);

    GPtrArray *words = g_ptr_array_new_with_free_func (g_free);
    GString *item = g_string_sized_new (32);

    if (*p == ']') {
        p++;
    } else {
        for (;;) {
            p = parse_string (p, item);
            /* Words end up in IBusText and travel over D-Bus, which only
             * carries valid UTF-8. */
            if (p == NULL || !g_utf8_validate (item->str, item->len, NULL))
                goto malformed;
            g_ptr_array_add (words, g_strdup (item->str));

            p = skip_ws (p);
            if (*p == ',') {
                p = skip_ws (p + 1);
                continue;
            }
            if (*p == ']') {
                p++;
                break;
            }
            goto malformed;
        }
    }
    if (*skip_ws (p) != '\0')
        goto malformed;

    g_string_free (item, TRUE);
    g_ptr_array_set_free_func (words, NULL);
    g_ptr_array_add (words, NULL);
    return (gchar **) g_ptr_array_free (words, FALSE);

malformed:
    g_string_free (item, TRUE);
    g_ptr_array_free (words, TRUE);
    return NULL;
}

gchar **
byk_userdict_words (ByakaronComposer *composer)
{
    char *json = composer != NULL ? byakaron_userdict_get (composer) : NULL;
    gchar **words = json != NULL ? byk_parse_json_strings (json) : NULL;
    if (json != NULL)
        byakaron_string_free (json);
    return words != NULL ? words : g_new0 (gchar *, 1);
}

gboolean
byk_userdict_contains (ByakaronComposer *composer, const gchar *word)
{
    gchar **words = byk_userdict_words (composer);
    const gboolean found = word != NULL && g_strv_contains ((const gchar *const *) words, word);
    g_strfreev (words);
    return found;
}
