-- Derive bigram backoff counts from trigrams: (prev,mid) and (mid,next).
-- Requires: bigrams(w1_id, w2_id, frequency, PRIMARY KEY (w1_id, w2_id))
INSERT INTO bigrams (w1_id, w2_id, frequency)
WITH edges AS (
    SELECT prev_id AS w1_id, mid_id AS w2_id, occurance AS frequency
    FROM word_triplets
    UNION ALL
    SELECT mid_id AS w1_id, next_id AS w2_id, occurance AS frequency
    FROM word_triplets
)
SELECT
    w1_id,
    w2_id,
    SUM(frequency)::bigint AS frequency
FROM edges
GROUP BY w1_id, w2_id
ON CONFLICT (w1_id, w2_id) DO UPDATE
SET frequency = EXCLUDED.frequency;
