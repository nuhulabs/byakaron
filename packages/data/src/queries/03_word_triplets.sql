-- Aggregate raw triplet rows into counted trigrams with word FKs.
-- Requires: word_triplets(prev_id, mid_id, next_id, occurance, PRIMARY KEY (...))
INSERT INTO word_triplets (prev_id, mid_id, next_id, occurance)
WITH triplet_counts AS (
    SELECT
        value,
        mid_value,
        next_value,
        COUNT(*)::int AS occurance
    FROM staging_word_triplets
    GROUP BY value, mid_value, next_value
)
SELECT
    w1.id,
    w2.id,
    w3.id,
    SUM(tc.occurance)
FROM triplet_counts tc
JOIN words w1 ON w1.value = tc.value
JOIN words w2 ON w2.value = tc.mid_value
JOIN words w3 ON w3.value = tc.next_value
GROUP BY
    w1.id,
    w2.id,
    w3.id;
