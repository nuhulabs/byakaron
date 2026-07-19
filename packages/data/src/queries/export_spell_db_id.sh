#!/usr/bin/env bash
# Assemble optimized spell_id.db (integer FK n-grams + deletes).
#
# Prerequisites:
#   1. Run Postgres 00–05, then 09_export_csvs_id.sql
#   2. CSVs under ./export_id/: dictionary.csv, bigrams.csv, trigrams.csv
#   3. zig build + sqlite3 on PATH
#
# Usage (from packages/data):
#   ./src/queries/export_spell_db_id.sh [export_dir] [spell_id.db]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_DIR="${1:-$ROOT/export_id}"
DB_PATH="${2:-$ROOT/spell_id.db}"
SCHEMA="$ROOT/src/queries/10_sqlite_schema_id.sql"

mkdir -p "$EXPORT_DIR"

if [[ ! -f "$EXPORT_DIR/dictionary.csv" ]]; then
  echo "missing $EXPORT_DIR/dictionary.csv — run 09_export_csvs_id.sql first" >&2
  exit 1
fi

# Expect id,word,frequency header for optimized path.
if ! head -n1 "$EXPORT_DIR/dictionary.csv" | grep -q '^id,'; then
  echo "dictionary.csv must start with id,word,frequency (got: $(head -n1 "$EXPORT_DIR/dictionary.csv"))" >&2
  exit 1
fi

echo "Generating SymSpell deletes (word_id mode) from dictionary.csv..."
(
  cd "$ROOT"
  zig build run -- --symspell-deletes "$EXPORT_DIR/dictionary.csv"
  if [[ -f "$ROOT/deletes.csv" && "$EXPORT_DIR" != "$ROOT" ]]; then
    mv -f "$ROOT/deletes.csv" "$EXPORT_DIR/deletes.csv"
  fi
)

if [[ ! -f "$EXPORT_DIR/deletes.csv" ]]; then
  echo "missing $EXPORT_DIR/deletes.csv after SymSpell generation" >&2
  exit 1
fi

rm -f "$DB_PATH"
sqlite3 "$DB_PATH" <"$SCHEMA"

sqlite3 "$DB_PATH" <<SQL
.mode csv
.import --skip 1 '$EXPORT_DIR/dictionary.csv' dictionary
.import --skip 1 '$EXPORT_DIR/deletes.csv' deletes
.import --skip 1 '$EXPORT_DIR/bigrams.csv' bigrams
.import --skip 1 '$EXPORT_DIR/trigrams.csv' trigrams
SQL

# Optional: rebuild to reclaim free pages after import
sqlite3 "$DB_PATH" "VACUUM; ANALYZE;"

echo "Wrote $DB_PATH"
sqlite3 "$DB_PATH" <<'SQL'
SELECT 'dictionary', COUNT(*) FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;
SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
FROM pragma_page_count(), pragma_page_size();
SQL
