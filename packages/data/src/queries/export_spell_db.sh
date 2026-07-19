#!/usr/bin/env bash
# Assemble spell.db from exported CSVs + SymSpell deletes.
#
# Prerequisites:
#   1. Run Postgres queries 00–06 (schema, load, aggregate, export CSVs)
#   2. CSVs under ./export/: dictionary.csv, bigrams.csv, trigrams.csv
#   3. zig build available in this package
#   4. sqlite3 on PATH
#
# Usage (from packages/data):
#   ./src/queries/export_spell_db.sh [export_dir] [spell.db]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_DIR="${1:-$ROOT/export}"
DB_PATH="${2:-$ROOT/spell.db}"
SCHEMA="$ROOT/src/queries/07_sqlite_schema.sql"

mkdir -p "$EXPORT_DIR"

if [[ ! -f "$EXPORT_DIR/dictionary.csv" ]]; then
  echo "missing $EXPORT_DIR/dictionary.csv — run 06_export_csvs.sql first" >&2
  exit 1
fi

echo "Generating SymSpell deletes from dictionary.csv..."
(
  cd "$ROOT"
  zig build run -- --symspell-deletes "$EXPORT_DIR/dictionary.csv"
  # Zig writes deletes.csv to cwd; move next to other exports if needed.
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

echo "Wrote $DB_PATH"
sqlite3 "$DB_PATH" "SELECT 'dictionary', COUNT(*) FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;"
