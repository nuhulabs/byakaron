-- Final SQLite product schema for spell suggestion / autosuggest.
-- Import after 06_export_csvs.sql + SymSpell deletes generation.
-- See export_spell_db.sh for the full assemble step.

PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

DROP TABLE IF EXISTS dictionary;
DROP TABLE IF EXISTS deletes;
DROP TABLE IF EXISTS bigrams;
DROP TABLE IF EXISTS trigrams;

CREATE TABLE dictionary (
    word TEXT NOT NULL PRIMARY KEY,
    frequency INTEGER NOT NULL
);

CREATE TABLE deletes (
    delete_key TEXT NOT NULL,
    word TEXT NOT NULL
);

CREATE TABLE bigrams (
    w1 TEXT NOT NULL,
    w2 TEXT NOT NULL,
    frequency INTEGER NOT NULL,
    PRIMARY KEY (w1, w2)
);

CREATE TABLE trigrams (
    w1 TEXT NOT NULL,
    w2 TEXT NOT NULL,
    w3 TEXT NOT NULL,
    frequency INTEGER NOT NULL,
    PRIMARY KEY (w1, w2, w3)
);

CREATE INDEX idx_deletes_key ON deletes (delete_key);
CREATE INDEX idx_dictionary_freq ON dictionary (frequency DESC);
CREATE INDEX idx_bigrams_w1_freq ON bigrams (w1, frequency DESC);
CREATE INDEX idx_trigrams_w1_w2_freq ON trigrams (w1, w2, frequency DESC);
