-- ============================================================================
-- Schema: Postgres staging forge vs SQLite product artifacts
-- ============================================================================
-- Preferred path (no Postgres):
--
--   zig build run -- --wordtriplets sentences.csv   → word_triplets.csv
--   zig build export                                → export/ + export_id/
--   zig build prepare                               → spell.db (+ webz default.db)
--   zig build prepare -- --debug-db                 → also spell_debug.db
--
-- `export` aggregates triplets in Zig. `prepare` (src/prepare.zig) runs SymSpell,
-- confusions, and sqlite3 import — it does not re-run export.
--
-- Legacy Postgres forge still documented under queries/01–09 if needed.
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

CREATE TABLE IF NOT EXISTS confusions (
    from_g TEXT NOT NULL,
    to_g TEXT NOT NULL,
    weight DOUBLE PRECISION NOT NULL,
    kind TEXT NOT NULL DEFAULT 'ortho',
    PRIMARY KEY (from_g, to_g, kind)
);

CREATE INDEX IF NOT EXISTS idx_word_triplets_prev_mid
    ON word_triplets (prev_id, mid_id);

CREATE INDEX IF NOT EXISTS idx_bigrams_w1
    ON bigrams (w1_id);

-- --------------------------------------------------------------------------
-- SQLite A — text keys (07_sqlite_schema.sql)  [debug only]
-- --------------------------------------------------------------------------
-- dictionary(word TEXT PRIMARY KEY, frequency INTEGER)
-- deletes(delete_key TEXT, word TEXT)
-- bigrams(w1 TEXT, w2 TEXT, frequency INTEGER, PRIMARY KEY (w1, w2))
-- trigrams(w1 TEXT, w2 TEXT, w3 TEXT, frequency INTEGER, PRIMARY KEY (w1, w2, w3))

-- --------------------------------------------------------------------------
-- SQLite B — integer FKs (10_sqlite_schema_id.sql)  [spell.db product]
-- --------------------------------------------------------------------------
-- dictionary(id INTEGER PRIMARY KEY, word TEXT UNIQUE, frequency INTEGER)
-- deletes(delete_key TEXT, word_id INTEGER)
-- bigrams(w1_id, w2_id, frequency, PRIMARY KEY (w1_id, w2_id))
-- trigrams(w1_id, w2_id, w3_id, frequency, PRIMARY KEY (w1_id, w2_id, w3_id))
-- confusions(from_g, to_g, weight, kind)
-- ============================================================================
