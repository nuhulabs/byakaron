-- Aggregate word_triplets.csv into lexicon / n-gram tables (SQLite forge).
-- Invoked by prepare_spell_dbs.sh — replaces Postgres queries 01–05 + 06/09 export.
--
-- Expects:
--   staging(value, mid_value, next_value) already imported
--   temp tables are created here
--
-- Produces (when called via the shell wrapper):
--   export/dictionary.csv, bigrams.csv, trigrams.csv
--   export_id/dictionary.csv, bigrams.csv, trigrams.csv

PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
PRAGMA temp_store = FILE;
PRAGMA cache_size = -200000;

DROP TABLE IF EXISTS dictionary_all;
DROP TABLE IF EXISTS bigrams_all;
DROP TABLE IF EXISTS trigrams_all;
DROP TABLE IF EXISTS dict_id;

-- Unigram: each triplet position contributes one count per raw row.
CREATE TABLE dictionary_all AS
SELECT word, SUM(n) AS frequency
FROM (
    SELECT value AS word, COUNT(*) AS n FROM staging GROUP BY value
    UNION ALL
    SELECT mid_value, COUNT(*) FROM staging GROUP BY mid_value
    UNION ALL
    SELECT next_value, COUNT(*) FROM staging GROUP BY next_value
)
GROUP BY word;

CREATE INDEX idx_dict_freq ON dictionary_all (frequency DESC);

-- Bigram backoff: (prev,mid) and (mid,next) edges.
CREATE TABLE bigrams_all AS
SELECT w1, w2, SUM(n) AS frequency
FROM (
    SELECT value AS w1, mid_value AS w2, COUNT(*) AS n
    FROM staging GROUP BY value, mid_value
    UNION ALL
    SELECT mid_value, next_value, COUNT(*)
    FROM staging GROUP BY mid_value, next_value
)
GROUP BY w1, w2;

CREATE INDEX idx_bigrams_freq ON bigrams_all (frequency DESC);

-- Trigram counts.
CREATE TABLE trigrams_all AS
SELECT
    value AS w1,
    mid_value AS w2,
    next_value AS w3,
    COUNT(*) AS frequency
FROM staging
GROUP BY value, mid_value, next_value;

CREATE INDEX idx_trigrams_freq ON trigrams_all (frequency DESC);

-- Staging is no longer needed (saves disk during export).
DROP TABLE IF EXISTS staging;
VACUUM;
