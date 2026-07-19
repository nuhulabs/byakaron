-- Export filtered, text-keyed CSVs for the SQLite spell artifact.
-- Adjust :min_frequency (default 2) to drop rare noise before shipping.
-- Paths assume the same container layout as 01_staging_word_triplets.sql.

\set min_frequency 2

COPY (
    SELECT w.value AS word, d.frequency
    FROM dictionary d
    JOIN words w ON w.id = d.word_id
    WHERE d.frequency >= :min_frequency
    ORDER BY d.frequency DESC, w.value
) TO '/byakaron/data/export/dictionary.csv'
WITH (FORMAT CSV, HEADER true);

COPY (
    SELECT w1.value AS w1, w2.value AS w2, b.frequency
    FROM bigrams b
    JOIN words w1 ON w1.id = b.w1_id
    JOIN words w2 ON w2.id = b.w2_id
    WHERE b.frequency >= :min_frequency
    ORDER BY b.frequency DESC
) TO '/byakaron/data/export/bigrams.csv'
WITH (FORMAT CSV, HEADER true);

COPY (
    SELECT
        w1.value AS w1,
        w2.value AS w2,
        w3.value AS w3,
        t.occurance AS frequency
    FROM word_triplets t
    JOIN words w1 ON w1.id = t.prev_id
    JOIN words w2 ON w2.id = t.mid_id
    JOIN words w3 ON w3.id = t.next_id
    WHERE t.occurance >= :min_frequency
    ORDER BY t.occurance DESC
) TO '/byakaron/data/export/trigrams.csv'
WITH (FORMAT CSV, HEADER true);

-- deletes.csv is produced next:
--   zig build run -- --symspell-deletes export/dictionary.csv
