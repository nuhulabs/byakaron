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
#include "corrector.h"
#include "userdict.h"
#include <glib/gstdio.h>

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

static void smoke_on_ready(const gchar *word, gpointer data)
{
    struct { GMainLoop *loop; gchar *word; } *got = data;
    g_free(got->word);
    got->word = g_strdup(word);
    g_main_loop_quit(got->loop);
}

static gboolean smoke_quit(gpointer loop)
{
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

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
            /* Arrow keys: highlight, Enter commits it; Space never does. */
            {
                gchar **cands;
                for (i = 0; i < 3; i++) { o = byk_composer_key(c, (guint) ami[i], 0); g_free(o.commit); }
                cands = byk_composer_candidates(c);
                const int none = byk_composer_cursor(c) == -1;
                o = byk_composer_key(c, 0xff54, 0); g_free(o.commit); /* Down */
                const int first = byk_composer_cursor(c) == 0;
                o = byk_composer_key(c, 0xff54, 0); g_free(o.commit); /* Down */
                const int second = byk_composer_cursor(c) == 1 && o.action == BYK_ACT_EAT;
                gchar *want = cands && cands[1] ? g_strdup(cands[1]) : NULL;
                o = byk_composer_key(c, 0xff0d, 0); /* Return */
                const int enter_ok = o.action == BYK_ACT_COMMIT && !o.pass_key && want &&
                                     o.commit && strcmp(o.commit, want) == 0;
                printf("  %-4s %-28s -> %s\n", none && first && second && enter_ok ? "ok" : "FAIL",
                       "Down Down Enter picks #2", o.commit ? o.commit : "(none)");
                if (!(none && first && second && enter_ok)) failures++;
                g_free(o.commit); g_free(want);

                for (i = 0; i < 3; i++) { o = byk_composer_key(c, (guint) ami[i], 0); g_free(o.commit); }
                o = byk_composer_key(c, 0xff54, 0); g_free(o.commit); /* Down -> 0 */
                o = byk_composer_key(c, 0xff52, 0); g_free(o.commit); /* Up -> none */
                const int cleared = byk_composer_cursor(c) == -1;
                o = byk_composer_key(c, 0xff0d, 0); /* Return: typed word, Enter passes */
                const int typed = cleared && o.action == BYK_ACT_COMMIT && o.pass_key &&
                                  o.commit && strcmp(o.commit, "আমি") == 0;
                printf("  %-4s %-28s -> %s\n", typed ? "ok" : "FAIL",
                       "Up past top: Enter types word", o.commit ? o.commit : "(none)");
                if (!typed) failures++;
                g_free(o.commit);

                for (i = 0; i < 3; i++) { o = byk_composer_key(c, (guint) ami[i], 0); g_free(o.commit); }
                for (i = 0; i < 10; i++) { o = byk_composer_key(c, 0xff53, 0); g_free(o.commit); } /* Right x10 */
                const int paged = byk_composer_cursor(c) == 9 && byk_composer_page(c) == 1;
                o = byk_composer_key(c, (guint) 'n', 0); g_free(o.commit); /* typing resets */
                const int reset = byk_composer_cursor(c) == -1 && byk_composer_page(c) == 0;
                printf("  %-4s %-28s -> %s\n", paged && reset ? "ok" : "FAIL",
                       "arrows cross pages, typing resets", paged && reset ? "yes" : "no");
                if (!(paged && reset)) failures++;
                o = byk_composer_key(c, 0x0020, 0); g_free(o.commit); /* Space commits typed */

                o = byk_composer_key(c, 0xff54, 0); /* Down with nothing pending */
                const int arrow_pass = o.action == BYK_ACT_PASS;
                printf("  %-4s %-28s -> %s\n", arrow_pass ? "ok" : "FAIL",
                       "Down with no word passes", arrow_pass ? "pass" : "eaten");
                if (!arrow_pass) failures++;
                g_free(o.commit);
            }

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

                /* NFC text spells য় as য + nukta; spell.db has U+09DF. */
                const int nfc = byk_spell_is_correct(spell, "আমায়");
                printf("  %-4s %-28s -> %d\n", nfc == 1 ? "ok" : "FAIL",
                       "is_correct NFC আমায়", nfc);
                if (nfc != 1) failures++;

                /* Would kill the process inside the engine without the guard. */
                const int bad = byk_spell_is_correct(spell, "\xa6\xae");
                printf("  %-4s %-28s -> %d\n", bad == -1 ? "ok" : "FAIL",
                       "invalid UTF-8 rejected", bad);
                if (bad != -1) failures++;

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

    puts("spelling corrections in suggestions:");
    {
        gchar *db_path = byk_spell_locate_db();
        if (db_path == NULL) {
            puts("  skip spell.db not present (prepare_spell_db.sh)");
        } else {
            g_free(db_path);
            BykCorrector *corr = byk_corrector_new(FALSE, NULL, NULL);
            BykComposer *c = byk_composer_new();
            byk_composer_set_corrector(c, corr);
            BykOutcome o;

            /* Typed word first, corrections after; worst keystroke timed. */
            gint64 worst = 0;
            for (const char *p = "sonar"; *p; p++) {
                const gint64 t0 = g_get_monotonic_time();
                o = byk_composer_key(c, (guint) *p, 0);
                worst = MAX(worst, g_get_monotonic_time() - t0);
                g_free(o.commit);
            }
            gchar **cands = byk_composer_candidates(c);
            const int listed = cands && cands[0] && strcmp(cands[0], "সনার") == 0 &&
                               cands[1] && strcmp(cands[1], "সোনার") == 0;
            printf("  %-4s %-28s -> %s, %s\n", listed ? "ok" : "FAIL", "sonar lists সনার, সোনার",
                   cands && cands[0] ? cands[0] : "(none)", cands && cands[0] && cands[1] ? cands[1] : "(none)");
            if (!listed) failures++;
            printf("  info slowest keystroke (inline, cold) %.1f ms\n", worst / 1000.0);

            o = byk_composer_key(c, 0x0032, 0); /* '2' */
            const int picked = o.action == BYK_ACT_COMMIT && o.commit && strcmp(o.commit, "সোনার") == 0;
            printf("  %-4s %-28s -> %s\n", picked ? "ok" : "FAIL", "2 picks the correction",
                   o.commit ? o.commit : "(none)");
            if (!picked) failures++;
            g_free(o.commit);

            /* Correctly spelled words keep the normal list (no corrections). */
            for (const char *p = "bangla"; *p; p++) { o = byk_composer_key(c, (guint) *p, 0); g_free(o.commit); }
            cands = byk_composer_candidates(c);
            const int normal = cands && cands[0] && strcmp(cands[0], "বাংলা") == 0;
            printf("  %-4s %-28s -> %s\n", normal ? "ok" : "FAIL", "bangla keeps its own list",
                   cands && cands[0] ? cands[0] : "(none)");
            if (!normal) failures++;
            o = byk_composer_key(c, 0xff1b, 0); g_free(o.commit);

            /* The setting turns them off. */
            byk_composer_set_corrections(c, FALSE);
            for (const char *p = "jibon"; *p; p++) { o = byk_composer_key(c, (guint) *p, 0); g_free(o.commit); }
            const int off = !byk_composer_table_visible(c);
            byk_composer_set_corrections(c, TRUE); /* live: the list appears */
            cands = byk_composer_candidates(c);
            const int back_on = cands && cands[1] && strcmp(cands[1], "জীবন") == 0;
            printf("  %-4s %-28s -> %s\n", off && back_on ? "ok" : "FAIL", "setting off/on (jibon)",
                   back_on ? cands[1] : "(none)");
            if (!(off && back_on)) failures++;
            o = byk_composer_key(c, 0xff1b, 0); g_free(o.commit);

            byk_composer_free(c);
            byk_corrector_free(corr);

            /* Threaded: nothing on the first ask, `ready` on the main loop, then cached. */
            GMainLoop *loop = g_main_loop_new(NULL, FALSE);
            struct { GMainLoop *loop; gchar *word; } got = { loop, NULL };
            corr = byk_corrector_new(TRUE, smoke_on_ready, &got);
            gchar **first = byk_corrector_get(corr, "শুন্দর");
            const guint timeout = g_timeout_add_seconds(5, smoke_quit, loop);
            g_main_loop_run(loop);
            g_source_remove(timeout);
            gchar **second = byk_corrector_get(corr, "শুন্দর");
            const int threaded = first == NULL && g_strcmp0(got.word, "শুন্দর") == 0 &&
                                 second && second[0] && strcmp(second[0], "সুন্দর") == 0;
            printf("  %-4s %-28s -> %s\n", threaded ? "ok" : "FAIL", "threaded: ready, then cached",
                   second && second[0] ? second[0] : "(none)");
            if (!threaded) failures++;
            g_strfreev(first); g_strfreev(second); g_free(got.word);
            byk_corrector_free(corr);
            g_main_loop_unref(loop);
        }
    }

    puts("personal dictionary:");
    {
        gchar *dir = g_dir_make_tmp("byk-userdict-XXXXXX", NULL);
        gchar *path = g_build_filename(dir, "sub", "user-words.txt", NULL);
        g_setenv("BYAKARON_USER_DICT", path, TRUE);

        BykUserDict *d = byk_userdict_new();
        const int empty = byk_userdict_count(d) == 0;
        GError *err = NULL;
        /* য় spelled as য + nukta (NFD) must be the same entry as U+09DF. */
        const int added = byk_userdict_add(d, "জিবন", &err) &&
                          byk_userdict_add(d, "আমায়", &err) &&
                          byk_userdict_add(d, " জিবন ", &err);
        const int nfc = byk_userdict_contains(d, "আমায়") && byk_userdict_count(d) == 2;
        gchar **pre = byk_userdict_prefix(d, "জি", 5);
        const int prefix = pre[0] && strcmp(pre[0], "জিবন") == 0 && pre[1] == NULL;
        g_strfreev(pre);
        printf("  %-4s %-28s -> %s\n", empty && added && nfc && prefix ? "ok" : "FAIL",
               "add, NFC, prefix", path);
        if (!(empty && added && nfc && prefix)) failures++;

        BykUserDict *again = byk_userdict_new();
        const int reloaded = byk_userdict_contains(again, "জিবন") && byk_userdict_count(again) == 2;
        printf("  %-4s %-28s -> %u words\n", reloaded ? "ok" : "FAIL", "saved and read back",
               byk_userdict_count(again));
        if (!reloaded) failures++;

        /* Another process (the app) changes the file: the reader notices once
         * its one-second check comes round, not before. */
        byk_userdict_remove(d, "আমায়", NULL);
        const int throttled = !byk_userdict_reload_if_changed(again);
        g_usleep(1100 * 1000);
        const int noticed = byk_userdict_reload_if_changed(again) &&
                            !byk_userdict_contains(again, "আমায়") && byk_userdict_count(again) == 1;
        printf("  %-4s %-28s -> %s\n", throttled && noticed ? "ok" : "FAIL", "other process's change seen",
               noticed ? "yes" : "no");
        if (!(throttled && noticed)) failures++;

        /* Keyboard: a saved word is suggested while typing its start, and is
         * never offered corrections. */
        BykCorrector *corr = byk_corrector_new(FALSE, NULL, NULL);
        BykComposer *c = byk_composer_new();
        byk_composer_set_corrector(c, corr);
        byk_composer_set_userdict(c, again);
        BykOutcome o;
        for (const char *p = "jib"; *p; p++) { o = byk_composer_key(c, (guint) *p, 0); g_free(o.commit); }
        gchar **cands = byk_composer_candidates(c);
        int suggested = 0;
        for (guint i = 0; cands && cands[i] && i < 3; i++)
            if (strcmp(cands[i], "জিবন") == 0) suggested = 1;
        printf("  %-4s %-28s -> %s\n", suggested ? "ok" : "FAIL", "jib suggests saved জিবন",
               cands && cands[1] ? cands[1] : "(none)");
        if (!suggested) failures++;
        for (const char *p = "on"; *p; p++) { o = byk_composer_key(c, (guint) *p, 0); g_free(o.commit); }
        const int no_fix = !byk_composer_table_visible(c);
        printf("  %-4s %-28s -> %s\n", no_fix ? "ok" : "FAIL", "jibon: saved, no corrections",
               no_fix ? "no list" : "list shown");
        if (!no_fix) failures++;
        o = byk_composer_key(c, 0xff1b, 0); g_free(o.commit);
        byk_composer_free(c);
        byk_corrector_free(corr);

        byk_userdict_free(again);
        byk_userdict_free(d);
        g_unsetenv("BYAKARON_USER_DICT");
        g_remove(path);
        gchar *sub = g_path_get_dirname(path);
        g_rmdir(sub);
        g_rmdir(dir);
        g_free(sub);
        g_free(path);
        g_free(dir);
        if (err) g_error_free(err);
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
