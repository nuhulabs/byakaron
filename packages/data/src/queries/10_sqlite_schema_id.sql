-- Optimized SQLite product schema: integer FKs into dictionary.
-- Import after 09_export_csvs_id.sql + SymSpell deletes (id mode).
-- See export_spell_db_id.sh for the full assemble step.

PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
PRAGMA foreign_keys = OFF;

DROP TABLE IF EXISTS deletes;
DROP TABLE IF EXISTS bigrams;
DROP TABLE IF EXISTS trigrams;
DROP TABLE IF EXISTS dictionary;

CREATE TABLE dictionary (
    id INTEGER NOT NULL PRIMARY KEY,
    word TEXT NOT NULL UNIQUE,
    frequency INTEGER NOT NULL
);

CREATE TABLE deletes (
    delete_key TEXT NOT NULL,
    word_id INTEGER NOT NULL
);

CREATE TABLE bigrams (
    w1_id INTEGER NOT NULL,
    w2_id INTEGER NOT NULL,
    frequency INTEGER NOT NULL,
    PRIMARY KEY (w1_id, w2_id)
);

CREATE TABLE trigrams (
    w1_id INTEGER NOT NULL,
    w2_id INTEGER NOT NULL,
    w3_id INTEGER NOT NULL,
    frequency INTEGER NOT NULL,
    PRIMARY KEY (w1_id, w2_id, w3_id)
);

CREATE INDEX idx_deletes_key ON deletes (delete_key);
CREATE INDEX idx_dictionary_word ON dictionary (word);
CREATE INDEX idx_dictionary_freq ON dictionary (frequency DESC);
CREATE INDEX idx_bigrams_w1_freq ON bigrams (w1_id, frequency DESC);
CREATE INDEX idx_trigrams_w1_w2_freq ON trigrams (w1_id, w2_id, frequency DESC);
