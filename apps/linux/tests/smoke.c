/*
 * Smoke test for libbyakaron's C ABI on Linux, and for the Core/ glue over it.
 *
 * Proves the Zig engine is reachable across the FFI boundary — if this fails,
 * nothing built on top of it can work. It needs no IBus daemon. The keyboard's
 * behaviour itself is tested in Zig (src/Composer.zig); here it is driven
 * through the same glue the IBus engine and Fcitx5 addon use (X11 keysyms ->
 * byk_keysym_to_key -> byakaron_composer_key), to prove the shell wiring.
 *
 * Build and run with: zig build linux-smoke
 */
#include <stdio.h>
#include <string.h>

#include "byakaron.h"
#include "composer.h"
#include "spell.h"
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

static int failures = 0;

static void expect(int ok, const char *what, const char *got)
{
    printf("  %-4s %-34s -> %s\n", ok ? "ok" : "FAIL", what, got ? got : "(null)");
    if (!ok) failures++;
}

/* A keystroke the way the IME shells send it. Returns the result's commit
 * (copied; g_free) and sets *handled. Modifier-only keys are not sent. */
static gchar *press(ByakaronComposer *c, guint keyval, int *handled)
{
    int kind;
    unsigned int ch;
    *handled = 0;
    if (!byk_keysym_to_key(keyval, &kind, &ch))
        return g_strdup("");
    ByakaronKeyResult r = byakaron_composer_key(c, kind, ch, 0);
    *handled = r.handled;
    return g_strdup(r.commit ? r.commit : "");
}

static void type(ByakaronComposer *c, const char *ascii)
{
    int handled;
    for (const char *p = ascii; *p; p++)
        g_free(press(c, (guint)(unsigned char)*p, &handled));
}

static void rm_rf(const gchar *dir)
{
    GDir *d = g_dir_open(dir, 0, NULL);
    const gchar *name;
    while (d && (name = g_dir_read_name(d)) != NULL) {
        gchar *path = g_build_filename(dir, name, NULL);
        g_remove(path);
        g_free(path);
    }
    if (d) g_dir_close(d);
    g_rmdir(dir);
}

int main(void)
{
    /* Settings, learned choices and personal words go to a scratch dir. */
    gchar *data_dir = g_dir_make_tmp("byk-smoke-XXXXXX", NULL);
    g_setenv("BYAKARON_DATA_DIR", data_dir, TRUE);
    /* No GSettings migration from the developer's desktop. */
    g_setenv("GSETTINGS_BACKEND", "memory", TRUE);

    ByakaronEngine *engine = byakaron_engine_create(BYAKARON_MODE_AVRO);
    if (!engine) {
        fprintf(stderr, "FAIL: byakaron_engine_create returned NULL\n");
        return 1;
    }

    puts("transliteration (avro):");
    for (int i = 0; i < CASE_COUNT; i++) {
        char *out = byakaron_engine_transliterate(engine, CASES[i].latin);
        const int ok = out && strcmp(out, CASES[i].bangla) == 0;
        expect(ok, CASES[i].latin, out);
        if (!ok) printf("       expected: %s\n", CASES[i].bangla);
        byakaron_string_free(out);
    }
    byakaron_engine_destroy(engine);

    puts("keysyms -> composer keys:");
    {
        static const struct { guint keyval; gboolean sent; int kind; unsigned int ch; const char *name; } KEYS[] = {
            { 'a',    TRUE,  BYAKARON_KEY_CHAR,      'a', "a" },
            { 'O',    TRUE,  BYAKARON_KEY_CHAR,      'O', "O" },
            { 0xffb5, TRUE,  BYAKARON_KEY_CHAR,      '5', "KP_5" },
            { 0x0020, TRUE,  BYAKARON_KEY_SPACE,     0,   "space" },
            { 0xff0d, TRUE,  BYAKARON_KEY_ENTER,     0,   "Return" },
            { 0xff8d, TRUE,  BYAKARON_KEY_ENTER,     0,   "KP_Enter" },
            { 0xfe20, TRUE,  BYAKARON_KEY_TAB,       0,   "ISO_Left_Tab" },
            { 0xff97, TRUE,  BYAKARON_KEY_UP,        0,   "KP_Up" },
            { 0xff9b, TRUE,  BYAKARON_KEY_PAGE_DOWN, 0,   "KP_Page_Down" },
            { 0xff50, TRUE,  BYAKARON_KEY_OTHER,     0,   "Home" },
            { 0xffe1, FALSE, 0,                      0,   "Shift_L (not sent)" },
            { 0xffe5, FALSE, 0,                      0,   "Caps_Lock (not sent)" },
            { 0xfe03, FALSE, 0,                      0,   "ISO_Level3_Shift (not sent)" },
        };
        for (size_t i = 0; i < sizeof KEYS / sizeof KEYS[0]; i++) {
            int kind = -1;
            unsigned int ch = 0;
            const gboolean sent = byk_keysym_to_key(KEYS[i].keyval, &kind, &ch);
            const int ok = sent == KEYS[i].sent &&
                           (!sent || (kind == KEYS[i].kind && ch == KEYS[i].ch));
            expect(ok, KEYS[i].name, ok ? "ok" : "wrong");
        }
    }

    puts("composer through the shell:");
    {
        ByakaronComposer *c = byk_composer_open(FALSE, NULL, NULL);
        expect(c != NULL, "byk_composer_open", c ? "created" : "NULL");
        if (c == NULL)
            return 1;

        gchar *settings_path = g_build_filename(data_dir, "settings.json", NULL);
        expect(g_file_test(settings_path, G_FILE_TEST_EXISTS), "first open writes settings.json",
               settings_path);
        g_free(settings_path);

        ByakaronComposerState st;
        int handled;
        type(c, "ami");
        byakaron_composer_state(c, &st);
        expect(st.composing && strcmp(st.preedit, "আমি") == 0, "\"ami\" preedit", st.preedit);
        expect(st.panel_visible && st.candidate_count > 0 &&
               strcmp(st.candidates[st.highlight], st.preedit) == 0,
               "preedit is the highlighted candidate", st.panel_visible ? "shown" : "hidden");

        gchar *out = press(c, 0x0020, &handled);
        expect(handled && strcmp(out, "আমি ") == 0, "Space commits word + space", out);
        g_free(out);
        byakaron_composer_state(c, &st);
        expect(!st.composing && !st.panel_visible, "nothing pending after", st.composing ? "composing" : "idle");

        /* Before anything is learned, which would change the highlight. */
        type(c, "bhal");
        g_free(press(c, 0xffe1, &handled)); /* Shift: not sent, the word goes on */
        type(c, "O");
        const char *word = byakaron_composer_flush(c);
        expect(strcmp(word, "ভালো") == 0, "Shift stays in the word (flush)", word);

        type(c, "bhalo");
        byakaron_composer_state(c, &st);
        const size_t pages = st.page_count;
        g_free(press(c, 0xff52, &handled)); /* Up from the first wraps */
        byakaron_composer_state(c, &st);
        expect(handled && st.page == pages - 1, "Up wraps to the last page",
               st.page == pages - 1 ? "last page" : "elsewhere");
        gchar *highlighted = g_strdup(st.preedit);
        out = press(c, 0xff8d, &handled); /* KP_Enter */
        expect(handled && strcmp(out, highlighted) == 0, "Enter commits the word only", out);
        g_free(out);
        g_free(highlighted);

        type(c, "ami");
        g_free(press(c, 0xff1b, &handled));
        byakaron_composer_state(c, &st);
        expect(handled && !st.composing, "Escape drops the word", st.composing ? "composing" : "dropped");

        BykSettings s;
        byk_settings_load(c, &s);
        expect(s.suggestions && s.bangla_digits && !s.vertical && s.candidates_per_page == 9,
               "default settings", "loaded");
        s.vertical = TRUE;
        s.candidates_per_page = 5;
        s.bangla_digits = FALSE;
        expect(byk_settings_save(c, &s), "save settings", "saved");
        BykSettings back;
        byk_settings_load(c, &back);
        expect(back.vertical && back.candidates_per_page == 5 && !back.bangla_digits,
               "settings round trip", "loaded");
        type(c, "bhalo");
        byakaron_composer_state(c, &st);
        expect(st.vertical && st.candidate_count <= 5, "composer obeys them",
               st.vertical ? "vertical" : "horizontal");
        byakaron_composer_reset(c);

        expect(byakaron_userdict_add(c, "জিবনানন্দ") == 1, "add a personal word", "added");
        expect(byk_userdict_contains(c, "জিবনানন্দ"), "contains it", "yes");
        gchar **words = byk_userdict_words(c);
        expect(g_strv_length(words) == 1, "one saved word", words[0]);
        g_strfreev(words);
        expect(byakaron_userdict_remove(c, "জিবনানন্দ") == 1, "remove it", "removed");
        expect(!byk_userdict_contains(c, "জিবনানন্দ"), "gone", "no");

        byakaron_composer_destroy(c);
    }

    puts("spell-check (local Byakaron.db):");
    {
        gchar *db_path = byk_spell_locate_db();
        if (db_path == NULL) {
            /* Typing and candidates do not need the file; CI never ships the
             * 364 MB database. Skip rather than fail so a fresh checkout still
             * goes green. */
            puts("  skip Byakaron.db not present (zig build db)");
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

                /* NFC text spells য় as য + nukta; Byakaron.db has U+09DF. */
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

    /* The ABI's word lists (personal dictionary, spell suggestions). */
    puts("JSON string-array parser:");
    static const struct {
        const char *json;
        const char *want; /* NULL = must be rejected; "" = empty array */
    } JSON_CASES[] = {
        { "[]",                     ""            },
        { " [ \"আম\" ] ",           "আম"          },
        { "[\"a\",\"b\"]",          "a"           },
        { "[\"say \\\"hi\\\"\"]",   "say \"hi\""  },
        { "[\"back\\\\slash\"]",    "back\\slash" },
        { "[\"\\u0985\"]",          "অ"           },
        { "[\"unterminated]",       NULL          },
        { "[42]",                   NULL          },
        { "[\"a\" \"b\"]",          NULL          }, /* missing comma */
        { "[\"a\"] trailing",       NULL          },
        { "{\"a\":1}",              NULL          },
        { "[\"\xa6\xae\"]",         NULL          }, /* not UTF-8 */
    };
    for (size_t i = 0; i < sizeof JSON_CASES / sizeof JSON_CASES[0]; i++) {
        gchar **got = byk_parse_json_strings(JSON_CASES[i].json);
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
        expect(ok, JSON_CASES[i].json, shown);
        g_strfreev(got);
    }

    rm_rf(data_dir);
    g_free(data_dir);

    printf("\n%s (%d failure%s)\n", failures ? "SMOKE TEST FAILED" : "smoke test passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
