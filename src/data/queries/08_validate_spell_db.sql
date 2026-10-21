-- ============================================================================
-- Validate / analyze / smoke-test spell.db
-- Usage: sqlite3 spell.db < src/queries/08_validate_spell_db.sql
-- ============================================================================

.headers on
.mode column
.timer on

-- --------------------------------------------------------------------------
-- 1. Sanity: row counts and size proxies
-- --------------------------------------------------------------------------

SELECT 'dictionary' AS table_name, COUNT(*) AS rows FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;

-- Orphan deletes: every deletes.word must exist in dictionary
SELECT COUNT(*) AS orphan_deletes
FROM deletes d
LEFT JOIN dictionary dict ON dict.word = d.word
WHERE dict.word IS NULL;

-- Orphan bigram endpoints
SELECT COUNT(*) AS orphan_bigram_ends
FROM (
    SELECT w1 AS w FROM bigrams
    UNION
    SELECT w2 FROM bigrams
) t
LEFT JOIN dictionary d ON d.word = t.w
WHERE d.word IS NULL;

-- Orphan trigram endpoints
SELECT COUNT(*) AS orphan_trigram_ends
FROM (
    SELECT w1 AS w FROM trigrams
    UNION
    SELECT w2 FROM trigrams
    UNION
    SELECT w3 FROM trigrams
) t
LEFT JOIN dictionary d ON d.word = t.w
WHERE d.word IS NULL;

-- --------------------------------------------------------------------------
-- 2. Frequency distribution (dictionary)
-- --------------------------------------------------------------------------

SELECT
    MIN(frequency) AS min_f,
    MAX(frequency) AS max_f,
    CAST(AVG(frequency) AS INTEGER) AS avg_f,
    CAST(SUM(frequency) AS INTEGER) AS total_tokens
FROM dictionary;

-- Histogram buckets (log-ish)
SELECT
    CASE
        WHEN frequency = 1 THEN '1'
        WHEN frequency < 5 THEN '2-4'
        WHEN frequency < 10 THEN '5-9'
        WHEN frequency < 50 THEN '10-49'
        WHEN frequency < 100 THEN '50-99'
        WHEN frequency < 1000 THEN '100-999'
        WHEN frequency < 10000 THEN '1k-9k'
        ELSE '10k+'
    END AS bucket,
    COUNT(*) AS words,
    CAST(SUM(frequency) AS INTEGER) AS mass
FROM dictionary
GROUP BY 1
ORDER BY MIN(frequency);

-- Top / bottom samples
SELECT word, frequency FROM dictionary ORDER BY frequency DESC LIMIT 20;
SELECT word, frequency FROM dictionary ORDER BY frequency ASC, word LIMIT 20;

-- --------------------------------------------------------------------------
-- 3. N-gram health
-- --------------------------------------------------------------------------

SELECT
    MIN(frequency) AS min_f,
    MAX(frequency) AS max_f,
    COUNT(*) AS rows
FROM bigrams;

SELECT
    MIN(frequency) AS min_f,
    MAX(frequency) AS max_f,
    COUNT(*) AS rows
FROM trigrams;

SELECT w1, w2, frequency FROM bigrams ORDER BY frequency DESC LIMIT 15;
SELECT w1, w2, w3, frequency FROM trigrams ORDER BY frequency DESC LIMIT 15;

-- Next-word suggest smoke: given last word "করা"
SELECT w2 AS suggestion, frequency
FROM bigrams
WHERE w1 = 'করা'
ORDER BY frequency DESC
LIMIT 10;

-- Next-word with trigram context: "থেকে সাল" → ?
SELECT w3 AS suggestion, frequency
FROM trigrams
WHERE w1 = 'থেকে' AND w2 = 'সাল'
ORDER BY frequency DESC
LIMIT 10;

-- --------------------------------------------------------------------------
-- 4. SymSpell / spell-check smoke tests
-- --------------------------------------------------------------------------

-- Exact lexicon hit
SELECT word, frequency FROM dictionary WHERE word = 'বাংলা';

-- Candidate generation via deletes: typed token missing one codepoint.
-- Example: look up delete keys that equal a known misspelling fragment.
-- Replace 'াংলা' with a real delete of a word you care about.
SELECT d.delete_key, d.word, dict.frequency
FROM deletes d
JOIN dictionary dict ON dict.word = d.word
WHERE d.delete_key = 'াংলা'
ORDER BY dict.frequency DESC
LIMIT 20;

-- How many dictionary words map to a given delete_key (collision pressure)
SELECT delete_key, COUNT(*) AS n_words
FROM deletes
GROUP BY delete_key
HAVING COUNT(*) > 20
ORDER BY n_words DESC
LIMIT 20;

-- Average deletes per dictionary word
SELECT
    (SELECT COUNT(*) FROM deletes) * 1.0 /
    (SELECT COUNT(*) FROM dictionary) AS avg_deletes_per_word;

-- Prefix autocomplete smoke
SELECT word, frequency
FROM dictionary
WHERE word LIKE 'বাং%'
ORDER BY frequency DESC
LIMIT 15;

-- --------------------------------------------------------------------------
-- 5. Auto-pick min_frequency (coverage elbow)
-- --------------------------------------------------------------------------
-- Idea: keep the largest threshold T such that words with frequency >= T
-- still cover >= target_coverage of total unigram mass (default 0.95).
-- Also report vocabulary size at each threshold so you can trade size vs recall.

WITH
params(target_coverage) AS (SELECT 0.95),
totals AS (
    SELECT SUM(frequency) * 1.0 AS total_mass, COUNT(*) AS vocab FROM dictionary
),
thresholds(t) AS (
    -- Edit this list freely; keep values ascending and unique.
    SELECT * FROM (VALUES
        (1),(2),(3),(5),(10),(20),(30),(50),(75),(100),
        (150),(200),(300),(500),(750),(1000),(2000),(5000),(10000)
    )
),
stats AS (
    SELECT
        th.t AS min_freq,
        COUNT(d.word) AS kept_words,
        SUM(d.frequency) * 1.0 AS kept_mass,
        totals.total_mass,
        totals.vocab
    FROM thresholds th
    CROSS JOIN totals
    LEFT JOIN dictionary d ON d.frequency >= th.t
    GROUP BY th.t, totals.total_mass, totals.vocab
),
scored AS (
    SELECT
        min_freq,
        kept_words,
        CAST(kept_mass AS INTEGER) AS kept_mass,
        ROUND(kept_mass / total_mass, 4) AS coverage,
        ROUND(kept_words * 1.0 / vocab, 4) AS vocab_frac
    FROM stats
)
SELECT *
FROM scored
ORDER BY min_freq;

-- Recommended: largest min_freq that still meets coverage target
WITH
params(target_coverage) AS (SELECT 0.95),
totals AS (
    SELECT SUM(frequency) * 1.0 AS total_mass FROM dictionary
),
thresholds(t) AS (
    SELECT * FROM (VALUES
        (1),(2),(3),(5),(10),(20),(30),(50),(75),(100),
        (150),(200),(300),(500),(750),(1000),(2000),(5000),(10000)
    )
),
passing AS (
    SELECT
        th.t AS min_freq,
        ROUND(SUM(d.frequency) * 1.0 / totals.total_mass, 4) AS coverage,
        COUNT(d.word) AS kept_words
    FROM thresholds th
    CROSS JOIN totals
    CROSS JOIN params
    JOIN dictionary d ON d.frequency >= th.t
    GROUP BY th.t, totals.total_mass, params.target_coverage
    HAVING SUM(d.frequency) * 1.0 / totals.total_mass >= params.target_coverage
)
SELECT
    min_freq AS recommended_min_freq,
    coverage,
    kept_words
FROM passing
ORDER BY min_freq DESC
LIMIT 1;

-- Same idea for bigrams / trigrams (n-gram mass coverage @ 90%)
WITH
params(target_coverage) AS (SELECT 0.90),
totals AS (SELECT SUM(frequency) * 1.0 AS total_mass FROM bigrams),
thresholds(t) AS (
    SELECT * FROM (VALUES
        (1),(2),(3),(5),(10),(20),(30),(50),(75),(100),(200),(500),(1000)
    )
),
passing AS (
    SELECT th.t AS min_freq,
           ROUND(SUM(b.frequency) * 1.0 / totals.total_mass, 4) AS coverage,
           COUNT(*) AS kept_rows
    FROM thresholds th
    CROSS JOIN totals
    CROSS JOIN params
    JOIN bigrams b ON b.frequency >= th.t
    GROUP BY th.t, totals.total_mass, params.target_coverage
    HAVING SUM(b.frequency) * 1.0 / totals.total_mass >= params.target_coverage
)
SELECT 'bigrams' AS table_name, min_freq AS recommended_min_freq, coverage, kept_rows
FROM passing
ORDER BY min_freq DESC
LIMIT 1;

WITH
params(target_coverage) AS (SELECT 0.90),
totals AS (SELECT SUM(frequency) * 1.0 AS total_mass FROM trigrams),
thresholds(t) AS (
    SELECT * FROM (VALUES
        (1),(2),(3),(5),(10),(20),(30),(50),(75),(100),(200),(500),(1000)
    )
),
passing AS (
    SELECT th.t AS min_freq,
           ROUND(SUM(t.frequency) * 1.0 / totals.total_mass, 4) AS coverage,
           COUNT(*) AS kept_rows
    FROM thresholds th
    CROSS JOIN totals
    CROSS JOIN params
    JOIN trigrams t ON t.frequency >= th.t
    GROUP BY th.t, totals.total_mass, params.target_coverage
    HAVING SUM(t.frequency) * 1.0 / totals.total_mass >= params.target_coverage
)
SELECT 'trigrams' AS table_name, min_freq AS recommended_min_freq, coverage, kept_rows
FROM passing
ORDER BY min_freq DESC
LIMIT 1;

-- --------------------------------------------------------------------------
-- 6. Frequency encoding size estimate (before rebuilding)
-- --------------------------------------------------------------------------
-- SQLite already varint-encodes integers: smaller values use fewer bytes.
-- Compare raw frequency vs log2 rank bucket storage.

SELECT
    'raw INTEGER' AS encoding,
    SUM(frequency) AS checksum_irrelevant,
    COUNT(*) AS rows
FROM dictionary;

-- log2-scaled short rank (0..63-ish): good enough for ranking, tiny ints
SELECT
    CAST(LOG2(frequency) AS INTEGER) AS log2_bucket,
    COUNT(*) AS words
FROM dictionary
GROUP BY 1
ORDER BY 1;

-- Quantile rank 0..255 (fits in 1 byte conceptually; SQLite still uses varint)
WITH ordered AS (
    SELECT
        word,
        frequency,
        NTILE(256) OVER (ORDER BY frequency) - 1 AS q8
    FROM dictionary
)
SELECT
    MIN(q8) AS min_q,
    MAX(q8) AS max_q,
    COUNT(*) AS words
FROM ordered;
