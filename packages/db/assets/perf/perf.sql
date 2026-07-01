-- ============================================================================
-- Spell Check Performance Optimization
-- ============================================================================
-- This file contains all the SQL needed for the spell-check materialized view
-- and indexes. Run this after the initial database setup.
-- ============================================================================

-- ============================================================================
-- 1. ENABLE REQUIRED EXTENSIONS
-- ============================================================================

-- pg_trgm: Provides trigram-based similarity functions and operators
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- fuzzystrmatch: Provides phonetic matching functions (soundex, levenshtein)
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;

-- ============================================================================
-- 2. CREATE MATERIALIZED VIEW
-- ============================================================================
-- This view pre-computes expensive joins and calculations:
-- - Joins words with their romanized forms
-- - Calculates word frequency from word_pairs
-- - Pre-computes soundex for phonetic matching
-- - Stores word length for filtering

DROP MATERIALIZED VIEW IF EXISTS word_lookup_mv;

CREATE MATERIALIZED VIEW word_lookup_mv AS
SELECT 
    w.id,
    w.value,
    COALESCE(rw.value, '') as romanized,
    soundex(COALESCE(rw.value, '')) as romanized_soundex,
    COALESCE(freq.frequency, 0) as frequency,
    length(w.value) as word_length
FROM public.words w
LEFT JOIN public.romanized_words rw ON w.id = rw.word_id
LEFT JOIN (
    -- Calculate frequency: sum of occurrences where word appears in any position
    SELECT 
        word_id,
        SUM(occurance) as frequency
    FROM (
        SELECT prev_id as word_id, occurance FROM public.word_pairs
        UNION ALL
        SELECT next_id as word_id, occurance FROM public.word_pairs
    ) word_occurrences
    GROUP BY word_id
) freq ON w.id = freq.word_id;

-- ============================================================================
-- 3. CREATE INDEXES ON MATERIALIZED VIEW
-- ============================================================================

-- Primary key equivalent for fast lookups by ID
CREATE UNIQUE INDEX IF NOT EXISTS idx_word_lookup_mv_id 
ON word_lookup_mv (id);

-- Index on word value for exact match lookups
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_value 
ON word_lookup_mv (value);

-- GIN index for trigram similarity on Bangla text
-- This enables the % operator for fast similarity searches
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_value_trgm 
ON word_lookup_mv USING gin (value gin_trgm_ops);

-- GIN index for trigram similarity on romanized text
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_romanized_trgm 
ON word_lookup_mv USING gin (romanized gin_trgm_ops);

-- Index on pre-computed soundex for phonetic matching
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_soundex 
ON word_lookup_mv (romanized_soundex);

-- Index on frequency for sorting by popularity
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_frequency 
ON word_lookup_mv (frequency DESC);

-- Composite index for common query patterns
CREATE INDEX IF NOT EXISTS idx_word_lookup_mv_freq_value 
ON word_lookup_mv (frequency DESC, value);

-- ============================================================================
-- 4. REFRESH COMMAND (run periodically to update the view)
-- ============================================================================
-- REFRESH MATERIALIZED VIEW CONCURRENTLY word_lookup_mv;
-- Note: CONCURRENTLY requires the unique index on id

-- ============================================================================
-- 5. VERIFY SETUP
-- ============================================================================

-- Check row count
SELECT 'word_lookup_mv row count' as check_name, COUNT(*) as result FROM word_lookup_mv;

-- Check indexes
SELECT 
    'Indexes on word_lookup_mv' as check_name,
    indexname,
    indexdef
FROM pg_indexes 
WHERE tablename = 'word_lookup_mv';

-- Sample data check
SELECT 
    'Sample data' as check_name,
    id, 
    value, 
    romanized, 
    romanized_soundex, 
    frequency,
    word_length
FROM word_lookup_mv 
WHERE frequency > 1000 
ORDER BY frequency DESC 
LIMIT 5;
