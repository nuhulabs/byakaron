-- Build the lexicon from every position in the staged triplets.
-- Requires: words(id SERIAL PRIMARY KEY, value TEXT UNIQUE)
INSERT INTO words (value)
SELECT DISTINCT value
FROM (
    SELECT value FROM staging_word_triplets
    UNION
    SELECT mid_value FROM staging_word_triplets
    UNION
    SELECT next_value FROM staging_word_triplets
) t
WHERE value IS NOT NULL
ON CONFLICT (value) DO NOTHING;
