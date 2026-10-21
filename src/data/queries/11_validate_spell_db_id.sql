-- Smoke-test optimized spell_id.db (integer FK schema).
-- Usage: sqlite3 spell_id.db < src/queries/11_validate_spell_db_id.sql

.headers on
.mode column

SELECT 'dictionary' AS t, COUNT(*) AS n FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams
UNION ALL SELECT 'confusions', COUNT(*) FROM confusions;

SELECT from_g, to_g, weight, kind FROM confusions ORDER BY kind, from_g, to_g LIMIT 20;

SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
FROM pragma_page_count(), pragma_page_size();

-- Orphans
SELECT COUNT(*) AS orphan_deletes
FROM deletes d LEFT JOIN dictionary dict ON dict.id = d.word_id
WHERE dict.id IS NULL;

SELECT COUNT(*) AS orphan_bigram_ends FROM (
    SELECT w1_id AS id FROM bigrams UNION SELECT w2_id FROM bigrams
) t LEFT JOIN dictionary d ON d.id = t.id WHERE d.id IS NULL;

SELECT COUNT(*) AS orphan_trigram_ends FROM (
    SELECT w1_id AS id FROM trigrams
    UNION SELECT w2_id FROM trigrams
    UNION SELECT w3_id FROM trigrams
) t LEFT JOIN dictionary d ON d.id = t.id WHERE d.id IS NULL;

-- Top words
SELECT id, word, frequency FROM dictionary ORDER BY frequency DESC LIMIT 10;

-- Next-word via ids: given surface "করা"
SELECT d2.word AS suggestion, b.frequency
FROM dictionary d1
JOIN bigrams b ON b.w1_id = d1.id
JOIN dictionary d2 ON d2.id = b.w2_id
WHERE d1.word = 'করা'
ORDER BY b.frequency DESC
LIMIT 10;

-- SymSpell: delete_key → word
SELECT d.delete_key, dict.word, dict.frequency
FROM deletes d
JOIN dictionary dict ON dict.id = d.word_id
WHERE d.delete_key = 'াংলা'
ORDER BY dict.frequency DESC
LIMIT 10;

-- Prefix via dictionary.word
SELECT id, word, frequency
FROM dictionary
WHERE word LIKE 'বাং%'
ORDER BY frequency DESC
LIMIT 10;
