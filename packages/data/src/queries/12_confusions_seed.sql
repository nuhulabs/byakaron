-- Orthographic confusion seed → Postgres staging (optional before SQLite export).
-- Shipable artifact for SQLite is confusions_seed.csv (imported by export_spell_db_id.sh).
-- Prefer zig --mine-confusions to reweight from the Wikipedia-derived lexicon.

CREATE TABLE IF NOT EXISTS confusions (
    from_g TEXT NOT NULL,
    to_g TEXT NOT NULL,
    weight DOUBLE PRECISION NOT NULL,
    kind TEXT NOT NULL DEFAULT 'ortho',
    PRIMARY KEY (from_g, to_g, kind)
);

INSERT INTO confusions (from_g, to_g, weight, kind) VALUES
    ('শ', 'ষ', 0.25, 'ortho'),
    ('ষ', 'শ', 0.25, 'ortho'),
    ('শ', 'স', 0.25, 'ortho'),
    ('স', 'শ', 0.25, 'ortho'),
    ('ষ', 'স', 0.30, 'ortho'),
    ('স', 'ষ', 0.30, 'ortho'),
    ('ন', 'ণ', 0.25, 'ortho'),
    ('ণ', 'ন', 0.25, 'ortho'),
    ('য', 'য়', 0.30, 'ortho'),
    ('য়', 'য', 0.30, 'ortho'),
    ('র', 'ড়', 0.40, 'ortho'),
    ('ড়', 'র', 0.40, 'ortho'),
    ('ড়', 'ঢ়', 0.35, 'ortho'),
    ('ঢ়', 'ড়', 0.35, 'ortho'),
    ('ি', 'ী', 0.20, 'matra'),
    ('ী', 'ি', 0.20, 'matra'),
    ('ু', 'ূ', 0.20, 'matra'),
    ('ূ', 'ু', 0.20, 'matra'),
    ('ে', 'ৈ', 0.30, 'matra'),
    ('ৈ', 'ে', 0.30, 'matra'),
    ('ো', 'ৌ', 0.30, 'matra'),
    ('ৌ', 'ো', 0.30, 'matra'),
    ('ং', 'ঙ', 0.35, 'ortho'),
    ('ঙ', 'ং', 0.35, 'ortho'),
    ('ং', 'ঁ', 0.40, 'ortho'),
    ('ঁ', 'ং', 0.40, 'ortho'),
    ('জ', 'য', 0.45, 'ortho'),
    ('য', 'জ', 0.45, 'ortho')
ON CONFLICT (from_g, to_g, kind) DO UPDATE SET weight = EXCLUDED.weight;
