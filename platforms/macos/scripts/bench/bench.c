// Benchmark: Zig (libbyakaron) vs riti (libavrobangla_engine) transliteration.
//
// The two engines have different shapes:
//   • Zig  — pure phonetic, one C call per word: byakaron_transliterate(AVRO, s).
//            This matches exactly how ZigTransliterator.swift drives it.
//   • riti — a stateful candidate engine. We run it in PHONETIC-ONLY mode
//            (set_phonetic_suggestion(false)), which is the closest analogue to
//            what Zig does and what the IME commits inline: feed the word's
//            keycodes one at a time, then read the single "lonely" suggestion.
//
// We time the per-word transliteration cost for each, averaged over many
// iterations, and report ns/word + words/sec + a throughput ratio.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "byakaron.h"
#include "avrobangla_engine.h" // pulls in riti.h

// ---- Test corpus: typical Avro phonetic words (Latin) ----------------------
static const char *WORDS[] = {
    "amar", "sOnar", "bangla", "ami", "tomake", "bhalObasi", "desh", "manush",
    "jIbon", "shopno", "alO", "andhokar", "prithibI", "akash", "batas", "nodI",
    "pahar", "shomudro", "briShTi", "rOd", "phul", "pakhi", "gaan", "kobita",
    "valObasa", "bondhu", "poribar", "shomoy", "itihash", "bhObiShyot",
};
enum { NWORDS = sizeof(WORDS) / sizeof(WORDS[0]) };

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// ---- Zig: one call per word, full lifecycle (alloc result + free) ----------
static size_t bench_zig(int iters, double *out_sec) {
    size_t checksum = 0;
    double t0 = now_sec();
    for (int it = 0; it < iters; it++) {
        for (int w = 0; w < NWORDS; w++) {
            char *r = byakaron_transliterate(BYAKARON_MODE_AVRO, WORDS[w]);
            if (r) {
                checksum += strlen(r);
                byakaron_string_free(r);
            }
        }
    }
    *out_sec = now_sec() - t0;
    return checksum;
}

// ---- Zig (persistent engine): build trie once, reuse across all calls ------
static size_t bench_zig_persistent(int iters, double *out_sec) {
    ByakaronEngine *eng = byakaron_engine_create(BYAKARON_MODE_AVRO);
    size_t checksum = 0;
    double t0 = now_sec();
    for (int it = 0; it < iters; it++) {
        for (int w = 0; w < NWORDS; w++) {
            char *r = byakaron_engine_transliterate(eng, WORDS[w]);
            if (r) {
                checksum += strlen(r);
                byakaron_string_free(r);
            }
        }
    }
    *out_sec = now_sec() - t0;
    byakaron_engine_destroy(eng);
    return checksum;
}

// ---- riti (phonetic-only): feed keycodes, read the lonely suggestion -------
static size_t bench_riti(RitiContext *ctx, int iters, double *out_sec) {
    size_t checksum = 0;
    double t0 = now_sec();
    for (int it = 0; it < iters; it++) {
        for (int w = 0; w < NWORDS; w++) {
            const char *s = WORDS[w];
            Suggestion *sug = NULL;
            for (const char *p = s; *p; p++) {
                uint16_t key = avro_keycode_for_char((uint32_t)(unsigned char)*p);
                if (key == 0) continue;
                if (sug) riti_suggestion_free(sug);
                sug = riti_get_suggestion_for_key(ctx, key, 0, 0);
            }
            if (sug) {
                char *txt = riti_suggestion_is_lonely(sug)
                              ? riti_suggestion_get_lonely_suggestion(sug)
                              : riti_suggestion_get_suggestion(sug, 0);
                if (txt) { checksum += strlen(txt); riti_string_free(txt); }
                riti_suggestion_free(sug);
            }
            // Reset the engine's buffer for the next word.
            if (riti_context_ongoing_input_session(ctx))
                riti_context_finish_input_session(ctx);
        }
    }
    *out_sec = now_sec() - t0;
    return checksum;
}

int main(int argc, char **argv) {
    const char *data_dir = (argc > 1) ? argv[1] : "data";
    const char *user_dir = (argc > 2) ? argv[2] : "/tmp/byakaron-bench-user";

    int iters = 20000; // 20k * 30 words = 600k transliterations per engine
    long total = (long)iters * NWORDS;

    // --- Set up riti in phonetic-only mode (matches the IME commit path) ----
    Config *cfg = riti_config_new();
    riti_config_set_layout_file(cfg, "avro_phonetic");
    riti_config_set_database_dir(cfg, data_dir);
    riti_config_set_user_dir(cfg, user_dir);
    riti_config_set_phonetic_suggestion(cfg, false); // phonetic-only
    riti_config_set_suggestion_include_english(cfg, true);
    RitiContext *ctx = riti_context_new_with_config(cfg);

    // --- Warm up all (page-in, fill caches) ---------------------------------
    double junk;
    bench_zig(50, &junk);
    bench_zig_persistent(50, &junk);
    bench_riti(ctx, 50, &junk);

    // --- Measure ------------------------------------------------------------
    double zig_sec, zigp_sec, riti_sec;
    size_t zc  = bench_zig(iters, &zig_sec);
    size_t zpc = bench_zig_persistent(iters, &zigp_sec);
    size_t rc  = bench_riti(ctx, iters, &riti_sec);

    double zig_ns  = zig_sec  / total * 1e9;
    double zigp_ns = zigp_sec / total * 1e9;
    double riti_ns = riti_sec / total * 1e9;

    printf("\n  Transliteration benchmark  (%ld words/engine, %d iters x %d words)\n",
           total, iters, NWORDS);
    printf("  ----------------------------------------------------------------------\n");
    printf("  %-30s %12s %16s\n", "engine", "ns/word", "words/sec");
    printf("  %-30s %12.1f %16.0f\n", "Zig (rebuild trie/call)", zig_ns,  total / zig_sec);
    printf("  %-30s %12.1f %16.0f\n", "Zig (persistent engine)", zigp_ns, total / zigp_sec);
    printf("  %-30s %12.1f %16.0f\n", "riti (phonetic-only)",    riti_ns, total / riti_sec);
    printf("  ----------------------------------------------------------------------\n");
    printf("  total time:  Zig %.3fs   Zig-persistent %.3fs   riti %.3fs\n",
           zig_sec, zigp_sec, riti_sec);
    if (zigp_ns < riti_ns)
        printf("  Zig (persistent) is %.2fx faster than riti per word\n", riti_ns / zigp_ns);
    else
        printf("  riti is %.2fx faster than Zig (persistent) per word\n", zigp_ns / riti_ns);
    printf("  (checksums: zig=%zu zig_p=%zu riti=%zu)\n\n", zc, zpc, rc);

    riti_context_free(ctx);
    riti_config_free(cfg);
    return 0;
}
