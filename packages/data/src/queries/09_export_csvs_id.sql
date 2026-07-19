-- Export filtered, ID-keyed CSVs for the optimized SQLite spell artifact.
-- Dense ids are remapped 1..N (by frequency DESC) so SQLite varints stay small.
-- Does not replace 06_export_csvs.sql (text-keyed legacy path).
--
-- Adjust $min_frequency before running. Paths assume container layout.

\set min_frequency 150

-- Temp mapping: Postgres word_id → dense export id
CREATE TEMP TABLE IF NOT EXISTS export_id_map (
    src_id INTEGER PRIMARY KEY,
    id INTEGER NOT NULL UNIQUE,
    word TEXT NOT NULL,
    frequency BIGINT NOT NULL
);

TRUNCATE export_id_map;

INSERT INTO export_id_map (src_id, id, word, frequency)
SELECT
    w.id AS src_id,
    ROW_NUMBER() OVER (ORDER BY d.frequency DESC, w.value)::int AS id,
    w.value AS word,
    d.frequency
FROM dictionary d
JOIN words w ON w.id = d.word_id
WHERE d.frequency >= $min_frequency;

COPY (
    SELECT id, word, frequency
    FROM export_id_map
    ORDER BY id
) TO '/byakaron/data/export_id/dictionary.csv'
WITH (FORMAT CSV, HEADER true);

COPY (
    SELECT m1.id AS w1_id, m2.id AS w2_id, b.frequency
    FROM bigrams b
    JOIN export_id_map m1 ON m1.src_id = b.w1_id
    JOIN export_id_map m2 ON m2.src_id = b.w2_id
    WHERE b.frequency >= $min_frequency
    ORDER BY b.frequency DESC
) TO '/byakaron/data/export_id/bigrams.csv'
WITH (FORMAT CSV, HEADER true);

COPY (
    SELECT
        m1.id AS w1_id,
        m2.id AS w2_id,
        m3.id AS w3_id,
        t.occurance AS frequency
    FROM word_triplets t
    JOIN export_id_map m1 ON m1.src_id = t.prev_id
    JOIN export_id_map m2 ON m2.src_id = t.mid_id
    JOIN export_id_map m3 ON m3.src_id = t.next_id
    WHERE t.occurance >= $min_frequency
    ORDER BY t.occurance DESC
) TO '/byakaron/data/export_id/trigrams.csv'
WITH (FORMAT CSV, HEADER true);

-- deletes.csv is produced next:
--   zig build run -- --symspell-deletes export_id/dictionary.csv
--   (auto-detects id,word,frequency → delete_key,word_id)
