-- Unigram frequencies from all three triplet positions (staging forge).
-- Requires: dictionary(word_id INTEGER PRIMARY KEY, frequency INTEGER)
-- Adjust MIN_FREQUENCY before export to keep the SQLite artifact small.
INSERT INTO dictionary (word_id, frequency)
WITH position_counts AS (
    SELECT prev_id AS word_id, occurance FROM word_triplets
    UNION ALL
    SELECT mid_id AS word_id, occurance FROM word_triplets
    UNION ALL
    SELECT next_id AS word_id, occurance FROM word_triplets
)
SELECT
    word_id,
    SUM(occurance)::bigint AS frequency
FROM position_counts
GROUP BY word_id
HAVING SUM(occurance) >= 1
ON CONFLICT (word_id) DO UPDATE
SET frequency = EXCLUDED.frequency;
