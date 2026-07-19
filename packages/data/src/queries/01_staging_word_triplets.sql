-- Load raw consecutive triplets from Zig output into Postgres staging.
-- Requires: staging_word_triplets(value TEXT, mid_value TEXT, next_value TEXT)
COPY staging_word_triplets
FROM '/byakaron/data/word_triplets.csv'
WITH (FORMAT CSV, HEADER true);
