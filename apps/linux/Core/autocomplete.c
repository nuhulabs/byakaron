#include "autocomplete.h"

#include "byakaron.h"

struct _BykAutoComplete {
    ByakaronAutoComplete *engine;
};

/*
 * Hand-parse the JSON rather than link json-glib.
 *
 * The producer is in this repository (stringifyWords / appendJsonString in
 * src/ffi/ffi.zig): a flat array of strings which escapes exactly `"`, `\`,
 * `\n`, `\r`, `\t` and emits everything else — Bangla included — as raw UTF-8.
 * That is a small enough grammar to read directly, and it keeps the engine's
 * runtime dependencies to ibus and glib, which every GNOME desktop already has.
 *
 * So the parser is strict on purpose: anything outside that grammar (a number, a
 * nested array, a \uXXXX escape) is a failure rather than a best-effort guess,
 * so a change on the Zig side surfaces here instead of silently mangling words.
 */

/* Advance past JSON whitespace. */
static const gchar *
skip_ws (const gchar *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
        p++;
    return p;
}

/*
 * Read one JSON string starting at the opening quote into `out`.
 *
 * Returns the position just past the closing quote, or NULL if the string is
 * unterminated or carries an escape the producer never emits.
 */
static const gchar *
parse_string (const gchar *p, GString *out)
{
    if (*p != '"')
        return NULL;
    p++;

    g_string_truncate (out, 0);
    while (*p != '"') {
        if (*p == '\0')
            return NULL; /* unterminated */

        if (*p != '\\') {
            g_string_append_c (out, *p++);
            continue;
        }

        p++;
        switch (*p) {
        case '"':  g_string_append_c (out, '"');  break;
        case '\\': g_string_append_c (out, '\\'); break;
        case 'n':  g_string_append_c (out, '\n'); break;
        case 'r':  g_string_append_c (out, '\r'); break;
        case 't':  g_string_append_c (out, '\t'); break;
        default:   return NULL; /* not an escape our producer emits */
        }
        p++;
    }

    return p + 1; /* past the closing quote */
}

gchar **
byk_autocomplete_parse_json_array (const gchar *json)
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
            if (p == NULL)
                goto malformed;

            /* Candidates end up in IBusText and travel over D-Bus, which only
             * carries valid UTF-8. Reject bad bytes here rather than let the
             * daemon drop the connection later. */
            if (!g_utf8_validate (item->str, item->len, NULL))
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
        goto malformed; /* trailing junk */

    g_string_free (item, TRUE);
    g_ptr_array_add (words, NULL);
    /* The NULL terminator is an element now, so hand the buffer over as-is. */
    return (gchar **) g_ptr_array_free (words, FALSE);

malformed:
    g_string_free (item, TRUE);
    g_ptr_array_free (words, TRUE);
    return NULL;
}

BykAutoComplete *
byk_autocomplete_new (void)
{
    ByakaronAutoComplete *engine = byakaron_ac_create ();
    if (engine == NULL) {
        g_warning ("byakaron: byakaron_ac_create failed");
        return NULL;
    }

    BykAutoComplete *self = g_new0 (BykAutoComplete, 1);
    self->engine = engine;
    return self;
}

void
byk_autocomplete_free (BykAutoComplete *self)
{
    if (self == NULL)
        return;

    byakaron_ac_destroy (self->engine);
    g_free (self);
}

gchar **
byk_autocomplete_prefix (BykAutoComplete *self, const gchar *prefix, gint limit)
{
    g_return_val_if_fail (self != NULL, NULL);
    g_return_val_if_fail (prefix != NULL, NULL);

    /* The engine returns [] for an empty prefix; skip the FFI round trip. */
    if (*prefix == '\0')
        return g_new0 (gchar *, 1);

    char *json = byakaron_ac_prefix (self->engine, prefix, limit);
    if (json == NULL)
        return NULL;

    gchar **words = byk_autocomplete_parse_json_array (json);
    byakaron_string_free (json);

    if (words == NULL)
        g_warning ("byakaron: could not parse autocomplete candidates");

    return words;
}
