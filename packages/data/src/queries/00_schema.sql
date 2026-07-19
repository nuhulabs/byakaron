-- ============================================================================
-- Schema: Postgres staging forge vs SQLite product artifacts
-- ============================================================================
-- Postgres is used only to load CSVs, aggregate, filter, and validate.
-- Two SQLite products can be built from the same staging tables:
--
-- A) Text-keyed (legacy / readable)
--   06_export_csvs.sql → zig --symspell-deletes → 07 + export_spell_db.sh
--   → spell.db
--
-- B) ID-keyed optimized (smaller)
--   09_export_csvs_id.sql → zig --symspell-deletes → 10 + export_spell_db_id.sh
--   → spell_id.db
--
-- Pipeline (shared staging):
--   word_triplets.csv
--     -> 01_staging_word_triplets.sql
--     -> 02_words.sql
--     -> 03_word_triplets.sql
--     -> 04_dictionary.sql
--     -> 05_bigrams.sql
-- ============================================================================

-- --------------------------------------------------------------------------
-- Postgres staging DDL (run once before queries 01–06 / 09)
-- --------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS staging_word_triplets (
    value TEXT,
    mid_value TEXT,
    next_value TEXT
);

CREATE TABLE IF NOT EXISTS words (
    id SERIAL PRIMARY KEY,
    value TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS word_triplets (
    prev_id INTEGER NOT NULL REFERENCES words (id),
    mid_id INTEGER NOT NULL REFERENCES words (id),
    next_id INTEGER NOT NULL REFERENCES words (id),
    occurance INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (prev_id, mid_id, next_id)
);

CREATE TABLE IF NOT EXISTS dictionary (
    word_id INTEGER PRIMARY KEY REFERENCES words (id),
    frequency BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS bigrams (
    w1_id INTEGER NOT NULL REFERENCES words (id),
    w2_id INTEGER NOT NULL REFERENCES words (id),
    frequency BIGINT NOT NULL,
    PRIMARY KEY (w1_id, w2_id)
);

CREATE INDEX IF NOT EXISTS idx_word_triplets_prev_mid
    ON word_triplets (prev_id, mid_id);

CREATE INDEX IF NOT EXISTS idx_bigrams_w1
    ON bigrams (w1_id);

-- --------------------------------------------------------------------------
-- SQLite A — text keys (07_sqlite_schema.sql)
-- --------------------------------------------------------------------------
-- dictionary(word TEXT PRIMARY KEY, frequency INTEGER)
-- deletes(delete_key TEXT, word TEXT)
-- bigrams(w1 TEXT, w2 TEXT, frequency INTEGER, PRIMARY KEY (w1, w2))
-- trigrams(w1 TEXT, w2 TEXT, w3 TEXT, frequency INTEGER, PRIMARY KEY (w1, w2, w3))

-- --------------------------------------------------------------------------
-- SQLite B — integer FKs (10_sqlite_schema_id.sql)  [preferred for size]
-- --------------------------------------------------------------------------
-- dictionary(id INTEGER PRIMARY KEY, word TEXT UNIQUE, frequency INTEGER)
-- deletes(delete_key TEXT, word_id INTEGER)
-- bigrams(w1_id, w2_id, frequency, PRIMARY KEY (w1_id, w2_id))
-- trigrams(w1_id, w2_id, w3_id, frequency, PRIMARY KEY (w1_id, w2_id, w3_id))
-- Dense ids remapped 1..N at export (09_export_csvs_id.sql).
