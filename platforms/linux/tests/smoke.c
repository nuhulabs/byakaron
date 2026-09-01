/*
 * Smoke test for libbyakaron's C ABI on Linux.
 *
 * Proves the Zig engine is reachable across the FFI boundary before any IBus
 * code exists — if this fails, nothing built on top of it can work.
 *
 * Build and run with: platforms/linux/scripts/smoke.sh
 */
#include <stdio.h>
#include <string.h>

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
    puts("autocomplete:");
    ByakaronAutoComplete *ac = byakaron_ac_create();
    if (!ac) {
        fprintf(stderr, "  FAIL byakaron_ac_create returned NULL\n");
        failures++;
    } else {
        char *json = byakaron_ac_prefix(ac, "আম", 5);
        printf("  %-4s %-20s -> %s\n", json ? "ok" : "FAIL", "prefix আম",
               json ? json : "(null)");
        if (!json) failures++;
        byakaron_string_free(json);
        byakaron_ac_destroy(ac);
    }

    printf("\n%s (%d failure%s)\n", failures ? "SMOKE TEST FAILED" : "smoke test passed",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
