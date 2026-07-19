-- Mine lexicon-internal confusion evidence:
-- count dictionary word pairs that differ by exactly one seeded confusion substitution.
-- Run against spell_id.db (SQLite) after dictionary + confusions are loaded.
--
-- Usage:
--   sqlite3 spell_id.db < src/queries/13_mine_confusions.sql
--
-- Output table confusions_mined can be merged into confusions weights later.
-- Prefer the Zig miner (`zig build run -- --mine-confusions …`) for large lexicons;
-- this SQL is a readable reference for the same idea.

DROP TABLE IF EXISTS confusions_mined;

CREATE TABLE confusions_mined (
    from_g TEXT NOT NULL,
    to_g TEXT NOT NULL,
    kind TEXT NOT NULL,
    pair_count INTEGER NOT NULL,
    PRIMARY KEY (from_g, to_g, kind)
);

-- For each confusion edge, count words where replacing from_g → to_g yields
-- another dictionary word. SQLite lacks a clean per-position replace enumerator,
-- so we approximate with REPLACE when from_g occurs once in the word.
INSERT INTO confusions_mined (from_g, to_g, kind, pair_count)
SELECT
    c.from_g,
    c.to_g,
    c.kind,
    COUNT(*) AS pair_count
FROM confusions c
JOIN dictionary d
  ON instr(d.word, c.from_g) > 0
 AND (length(d.word) - length(replace(d.word, c.from_g, ''))) / max(length(c.from_g), 1) = 1
JOIN dictionary d2
  ON d2.word = replace(d.word, c.from_g, c.to_g)
 AND d2.word != d.word
GROUP BY c.from_g, c.to_g, c.kind
HAVING COUNT(*) >= 2;

-- Reweight seed edges that have mining support (soft blend).
UPDATE confusions
SET weight = MAX(0.12, MIN(weight, 1.0 / (1.0 + LN(1.0 + (
    SELECT pair_count FROM confusions_mined m
    WHERE m.from_g = confusions.from_g
      AND m.to_g = confusions.to_g
      AND m.kind = confusions.kind
)))))
WHERE EXISTS (
    SELECT 1 FROM confusions_mined m
    WHERE m.from_g = confusions.from_g
      AND m.to_g = confusions.to_g
      AND m.kind = confusions.kind
);

SELECT 'mined edges', COUNT(*) FROM confusions_mined;
SELECT from_g, to_g, kind, pair_count FROM confusions_mined ORDER BY pair_count DESC LIMIT 20;
