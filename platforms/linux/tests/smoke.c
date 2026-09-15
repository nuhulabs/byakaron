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
#include "composer.h"
#include "spell.h"

/* Expected outputs are pinned so a regression in the engine is visible here. */
static const struct {
    const char *latin;
    const char *bangla;
} CASES[] = {
    { "ami",               "আমি" },
    { "bangla",            "বাংলা" },
    { "amar sonar bangla", "আমার সনার বাংলা" },
    { "kemon acho",        "কেমন আছ" },
    { "bhalO",             "ভালো" },
    { "achO",              "আছো" },
    { "kO",                "কো" },
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

    puts("composer (shared IME policy):");
    {
        BykComposer *c = byk_composer_new();
        if (!c || !byk_composer_ready(c)) {
            fprintf(stderr, "  FAIL byk_composer_new\n");
            failures++;
        } else {
            BykOutcome o;
            guint i;
            const char ami[] = { 'a', 'm', 'i' };
            for (i = 0; i < 3; i++) {
                o = byk_composer_key(c, (guint) ami[i], 0);
                if (o.action != BYK_ACT_EAT) failures++;
                g_free(o.commit);
            }
            gchar *pre = byk_composer_preedit(c);
            const int ami_ok = pre && strcmp(pre, "আমি") == 0;
            printf("  %-4s %-28s -> %s\n", ami_ok ? "ok" : "FAIL",
                   "type ami", pre ? pre : "(null)");
            if (!ami_ok) failures++;
            g_free(pre);

            const int listed = byk_composer_table_visible(c);
            printf("  %-4s %-28s -> %s\n", listed ? "ok" : "FAIL",
                   "candidates while typing", listed ? "yes" : "no");
            if (!listed) failures++;

            o = byk_composer_key(c, 0x0032, 0); /* '2' */
            const int picked = o.action == BYK_ACT_COMMIT && o.commit &&
                               strcmp(o.commit, "আমিন") == 0;
            printf("  %-4s %-28s -> %s\n", picked ? "ok" : "FAIL",
                   "2 picks candidate 2", o.commit ? o.commit : "(none)");
            if (!picked) failures++;
            g_free(o.commit);

            o = byk_composer_key(c, 0x0031, 0); /* '1' with no list */
            pre = byk_composer_preedit(c);
            const int digit = o.action == BYK_ACT_EAT && pre &&
                              strcmp(pre, "১") == 0;
            printf("  %-4s %-28s -> %s\n", digit ? "ok" : "FAIL",
                   "1 becomes ১", pre ? pre : "(null)");
            if (!digit) failures++;
            g_free(pre);
            g_free(o.commit);

            o = byk_composer_key(c, 0xff08, 0); /* BackSpace */
            g_free(o.commit);
            o = byk_composer_key(c, 0x0061, 0); /* a */
            g_free(o.commit);
            o = byk_composer_key(c, 0x006d, 0);
            g_free(o.commit);
            o = byk_composer_key(c, 0x0069, 0);
            g_free(o.commit);
            o = byk_composer_key(c, 0x0020, 0); /* space */
            const int spaced = o.action == BYK_ACT_COMMIT && o.commit &&
                               strcmp(o.commit, "আমি ") == 0;
            printf("  %-4s %-28s -> %s\n", spaced ? "ok" : "FAIL",
                   "space commits typed word", o.commit ? o.commit : "(none)");
            if (!spaced) failures++;
            g_free(o.commit);

            /* Punctuation is latin, not a commit-and-pass: Avro maps `.` → `।`. */
            o = byk_composer_key(c, (guint) '.', 0);
            pre = byk_composer_preedit(c);
            const int dari = o.action == BYK_ACT_EAT && pre &&
                             strcmp(pre, "।") == 0;
            printf("  %-4s %-28s -> %s\n", dari ? "ok" : "FAIL",
                   ". becomes ।", pre ? pre : "(null)");
            if (!dari) failures++;
            g_free(pre);
            g_free(o.commit);

            o = byk_composer_key(c, 0xff1b, 0); /* Escape */
            g_free(o.commit);
            {
                const char ami_dot[] = { 'a', 'm', 'i', '.' };
                for (i = 0; i < 4; i++) {
                    o = byk_composer_key(c, (guint) ami_dot[i], 0);
                    g_free(o.commit);
                }
            }
            pre = byk_composer_preedit(c);
            const int ami_dari = pre && strcmp(pre, "আমি।") == 0;
            printf("  %-4s %-28s -> %s\n", ami_dari ? "ok" : "FAIL",
                   "ami. is আমি।", pre ? pre : "(null)");
            if (!ami_dari) failures++;
            g_free(pre);

            o = byk_composer_key(c, 0x0020, 0);
            const int dari_commit = o.action == BYK_ACT_COMMIT && o.commit &&
                                    strcmp(o.commit, "আমি। ") == 0;
            printf("  %-4s %-28s -> %s\n", dari_commit ? "ok" : "FAIL",
                   "space commits আমি। ", o.commit ? o.commit : "(none)");
            if (!dari_commit) failures++;
            g_free(o.commit);

            byk_composer_set_phonetic_only(c, TRUE);
            {
                const char ami2[] = { 'a', 'm', 'i' };
                for (i = 0; i < 3; i++) {
                    o = byk_composer_key(c, (guint) ami2[i], 0);
                    g_free(o.commit);
                }
            }
            pre = byk_composer_preedit(c);
            const int phonetic_pre = pre && strcmp(pre, "আমি") == 0;
            const int phonetic_hide = !byk_composer_table_visible(c);
            printf("  %-4s %-28s -> %s\n", phonetic_pre ? "ok" : "FAIL",
                   "phonetic-only still types", pre ? pre : "(null)");
            printf("  %-4s %-28s -> %s\n", phonetic_hide ? "ok" : "FAIL",
                   "phonetic-only hides list", phonetic_hide ? "hidden" : "shown");
            if (!phonetic_pre) failures++;
            if (!phonetic_hide) failures++;
            g_free(pre);

            o = byk_composer_key(c, 0x0032, 0); /* '2' with no list */
            pre = byk_composer_preedit(c);
            const int phonetic_digit = o.action == BYK_ACT_EAT && pre &&
                                       strcmp(pre, "আমি২") == 0;
            printf("  %-4s %-28s -> %s\n", phonetic_digit ? "ok" : "FAIL",
                   "phonetic-only 2 is ২", pre ? pre : "(null)");
            if (!phonetic_digit) failures++;
            g_free(pre);
            g_free(o.commit);

            /* Shift must not commit: Avro o-kar is Shift+o (`bhalO` → ভালো).
             * IBus delivers Shift_L as its own key event before the letter. */
            o = byk_composer_key(c, 0xff1b, 0); /* Escape */
            g_free(o.commit);
            byk_composer_set_phonetic_only(c, FALSE);
            {
                const char bhal[] = { 'b', 'h', 'a', 'l' };
                for (i = 0; i < 4; i++) {
                    o = byk_composer_key(c, (guint) bhal[i], 0);
                    g_free(o.commit);
                }
            }
            o = byk_composer_key(c, 0xffe1, 0); /* Shift_L */
            const int shift_pass = o.action == BYK_ACT_PASS;
            printf("  %-4s %-28s -> %s\n", shift_pass ? "ok" : "FAIL",
                   "Shift does not commit", shift_pass ? "pass" : "commit");
            if (!shift_pass) failures++;
            g_free(o.commit);
            o = byk_composer_key(c, (guint) 'O', 0);
            g_free(o.commit);
            pre = byk_composer_preedit(c);
            const int bhalo_ok = pre && strcmp(pre, "ভালো") == 0;
            printf("  %-4s %-28s -> %s\n", bhalo_ok ? "ok" : "FAIL",
                   "bhal + Shift + O is ভালো", pre ? pre : "(null)");
            if (!bhalo_ok) failures++;
            g_free(pre);

            o = byk_composer_key(c, 0xff1b, 0);
            g_free(o.commit);
            {
                const char ach[] = { 'a', 'c', 'h' };
                for (i = 0; i < 3; i++) {
                    o = byk_composer_key(c, (guint) ach[i], 0);
                    g_free(o.commit);
                }
            }
            o = byk_composer_key(c, 0xffe5, 0); /* Caps_Lock */
            g_free(o.commit);
            o = byk_composer_key(c, (guint) 'O', 0);
            g_free(o.commit);
            pre = byk_composer_preedit(c);
            const int acho_ok = pre && strcmp(pre, "আছো") == 0;
            printf("  %-4s %-28s -> %s\n", acho_ok ? "ok" : "FAIL",
                   "ach + Caps + O is আছো", pre ? pre : "(null)");
            if (!acho_ok) failures++;
            g_free(pre);
        }
        byk_composer_free(c);
    }

    puts("spell-check (local spell.db):");
    {
        gchar *db_path = byk_spell_locate_db();
        if (db_path == NULL) {
            /* Typing and candidates do not need the file; CI never ships the
             * 364 MB database. Skip rather than fail so a fresh checkout still
             * goes green. */
            puts("  skip spell.db not present (prepare_spell_db.sh)");
        } else {
            g_free(db_path);
            BykSpell *spell = byk_spell_new(NULL);
            if (!spell) {
                fprintf(stderr, "  FAIL byk_spell_new returned NULL\n");
                failures++;
            } else {
                const int known = byk_spell_is_correct(spell, "আমি");
                printf("  %-4s %-28s -> %d\n", known == 1 ? "ok" : "FAIL",
                       "is_correct আমি", known);
                if (known != 1) failures++;

                const int unknown = byk_spell_is_correct(spell, "qqq");
                printf("  %-4s %-28s -> %d\n", unknown == 0 ? "ok" : "FAIL",
                       "is_correct qqq", unknown);
                if (unknown != 0) failures++;

                gchar **sug = byk_spell_suggest(spell, "আমী", 5);
                const int has_sug = sug && sug[0];
                printf("  %-4s %-28s -> %s\n", has_sug ? "ok" : "FAIL",
                       "suggest আমী", has_sug ? sug[0] : "(none)");
                if (!has_sug) failures++;
                g_strfreev(sug);

                byk_spell_free(spell);
            }
        }
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
