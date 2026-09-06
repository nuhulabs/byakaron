/*
 * Smoke test for libbyakaron's C ABI on Linux, and for the Core/ glue over it.
 *
 * Proves the Zig engine is reachable across the FFI boundary — if this fails,
 * nothing built on top of it can work. It needs no IBus daemon, which is what
 * makes it the right place for the candidate JSON parser: the parser's failure
 * paths cannot be reached through the engine, because the only producer in the
 * repository never emits malformed input.
 *
 * Build and run with: platforms/linux/scripts/smoke.sh
 */
#include <stdio.h>
#include <string.h>

#include "autocomplete.h"
#include "byakaron.h"

/* Expected outputs are pinned so a regression in the engine is visible here. */
static const struct {
    const char *latin;
    const char *bangla;
} CASES[] = {
    { "ami",               "আমি" },
    { "bangla",            "বাংলা" },
    { "amar sonar bangla", "আমার সনার বাংলা" },
    { "kemon acho",        "কেমন আছ" },
};
static const int CASE_COUNT = (int)(sizeof CASES / sizeof CASES[0]);

int main(void)
{
    int failures = 0;

    ByakaronEngine *engine = byakaron_engine_create(BYAKARON_MODE_AVRO);
    if (!engine) {
        fprintf(stderr, "FAIL: byakaron_engine_create returned NULL\n");
        return 1;
    }

    puts("transliteration (avro):");
    for (int i = 0; i < CASE_COUNT; i++) {
        char *out = byakaron_engine_transliterate(engine, CASES[i].latin);
        const int ok = out && strcmp(out, CASES[i].bangla) == 0;
        printf("  %-4s %-20s -> %s\n", ok ? "ok" : "FAIL", CASES[i].latin,
               out ? out : "(null)");
        if (!ok) {
            printf("       expected: %s\n", CASES[i].bangla);
            failures++;
        }
        byakaron_string_free(out);
    }
    byakaron_engine_destroy(engine);

    /* Round-trip through the reverse mode to exercise the second engine mode. */
    puts("transliteration (orva, reverse):");
    char *latin = byakaron_transliterate(BYAKARON_MODE_ORVA, "আমি");
    printf("  %-4s %-20s -> %s\n", latin ? "ok" : "FAIL", "আমি",
           latin ? latin : "(null)");
    if (!latin) failures++;
    byakaron_string_free(latin);

    /* Autocomplete is in-memory (no spell.db needed), so it must work already. */
    puts("autocomplete (Core wrapper):");
    BykAutoComplete *ac = byk_autocomplete_new();
    if (!ac) {
        fprintf(stderr, "  FAIL byk_autocomplete_new returned NULL\n");
        failures++;
    } else {
        /* The candidate window depends on three things this checks: that a
         * prefix finds words, that the word itself comes back first (so the
         * first candidate is a no-op choice), and that "no completions" is an
         * empty list rather than an error. */
        gchar **words = byk_autocomplete_prefix(ac, "আম", 5);
        const int found = words && words[0];
        printf("  %-4s %-28s -> %s\n", found ? "ok" : "FAIL", "prefix আম",
               found ? words[0] : "(none)");
        if (!found) failures++;

        const int exact_first = found && strcmp(words[0], "আম") == 0;
        printf("  %-4s %-28s -> %s\n", exact_first ? "ok" : "FAIL",
               "typed word ranks first", found ? words[0] : "(none)");
        if (!exact_first) failures++;
        g_strfreev(words);

        /* "সনার" is real Bangla but not a dictionary lemma. */
        words = byk_autocomplete_prefix(ac, "সনার", 5);
        const int empty = words && words[0] == NULL;
        printf("  %-4s %-28s -> %s\n", empty ? "ok" : "FAIL",
               "unknown prefix is empty", words ? (words[0] ? words[0] : "[]") : "(null)");
        if (!empty) failures++;
        g_strfreev(words);

        byk_autocomplete_free(ac);
    }

    /*
     * The parser is strict so that a change to the Zig side is loud rather than
     * silent. These cases are the contract: accept what ffi.zig emits, reject
     * everything else.
     */
    puts("candidate JSON parser:");
    static const struct {
        const char *json;
        const char *want; /* NULL = must be rejected; "" = empty array */
    } JSON_CASES[] = {
        { "[]",                     ""            },
        { " [ \"আম\" ] ",           "আম"          },
        { "[\"a\",\"b\"]",          "a"           },
        { "[\"say \\\"hi\\\"\"]",   "say \"hi\""  },
        { "[\"back\\\\slash\"]",    "back\\slash" },
        { "[\"tab\\there\"]",       "tab\there"   },
        { "[\"unterminated]",       NULL          },
        { "[\"\\u0985\"]",          NULL          }, /* ffi.zig never emits \u */
        { "[42]",                   NULL          },
        { "[\"a\" \"b\"]",          NULL          }, /* missing comma */
        { "[\"a\"] trailing",       NULL          },
        { "{\"a\":1}",              NULL          },
    };
    static const int JSON_COUNT = (int)(sizeof JSON_CASES / sizeof JSON_CASES[0]);

    for (int i = 0; i < JSON_COUNT; i++) {
        gchar **got = byk_autocomplete_parse_json_array(JSON_CASES[i].json);
        const char *want = JSON_CASES[i].want;

        int ok;
        const char *shown;
        if (want == NULL) {
            ok = got == NULL;
            shown = got ? "(accepted)" : "rejected";
        } else if (*want == '\0') {
            ok = got != NULL && got[0] == NULL;
            shown = ok ? "[]" : "(wrong)";
        } else {
            ok = got != NULL && got[0] != NULL && strcmp(got[0], want) == 0;
            shown = (got && got[0]) ? got[0] : "(none)";
        }

        printf("  %-4s %-28s -> %s\n", ok ? "ok" : "FAIL", JSON_CASES[i].json, shown);
        if (!ok) failures++;
        g_strfreev(got);
    }

    printf("\n%s (%d failure%s)\n", failures ? "SMOKE TEST FAILED" : "smoke test passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
