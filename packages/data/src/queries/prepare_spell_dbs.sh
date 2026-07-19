#!/usr/bin/env bash
# Assemble spell.db + spell_debug.db from export CSVs.
#
# Prefer:
#   zig build export     # word_triplets.csv → export/ + export_id/  (Zig, fast)
#   zig build prepare    # runs export, then SymSpell + sqlite3 assemble
#
# Or invoke assemble only (CSVs already present):
#   ./src/queries/prepare_spell_dbs.sh [path/to/data-exe]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DATA_EXE="${1:-${DATA_EXE:-}}"
if [[ -z "$DATA_EXE" ]]; then
  if [[ -x "$ROOT/zig-out/bin/data" ]]; then
    DATA_EXE="$ROOT/zig-out/bin/data"
  else
    echo "error: data executable not found; pass it as \$1 or run via: zig build prepare" >&2
    exit 1
  fi
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "error: sqlite3 not found on PATH" >&2
  exit 1
fi

EXPORT_DEBUG="$ROOT/export"
EXPORT_ID="$ROOT/export_id"
SEED="$ROOT/src/queries/confusions_seed.csv"
SCHEMA_DEBUG="$ROOT/src/queries/07_sqlite_schema.sql"
SCHEMA_ID="$ROOT/src/queries/10_sqlite_schema_id.sql"
DB_DEBUG="$ROOT/spell_debug.db"
DB_ID="$ROOT/spell.db"

need_file() {
  local f="$1" hint="$2"
  if [[ ! -f "$f" ]]; then
    echo "error: missing $f" >&2
    echo "  $hint" >&2
    exit 1
  fi
}

run_data() {
  "$DATA_EXE" "$@"
}

import_csv() {
  local db="$1" table="$2" csv="$3"
  sqlite3 "$db" <<SQL
.mode csv
.import --skip 1 '$csv' $table
SQL
}

echo "==> data exe: $DATA_EXE"
echo "==> sqlite3:   $(command -v sqlite3)"

# --------------------------------------------------------------------------
# spell_debug.db — text-keyed (export/)
# --------------------------------------------------------------------------
need_file "$EXPORT_DEBUG/dictionary.csv" "run: zig build export"
need_file "$EXPORT_DEBUG/bigrams.csv" "run: zig build export"
need_file "$EXPORT_DEBUG/trigrams.csv" "run: zig build export"

if ! head -n1 "$EXPORT_DEBUG/dictionary.csv" | grep -q '^word,'; then
  echo "error: export/dictionary.csv must start with word,frequency (got: $(head -n1 "$EXPORT_DEBUG/dictionary.csv"))" >&2
  exit 1
fi

echo "==> SymSpell deletes (text) from export/dictionary.csv"
run_data --symspell-deletes "$EXPORT_DEBUG/dictionary.csv"
mv -f "$ROOT/deletes.csv" "$EXPORT_DEBUG/deletes.csv"

echo "==> Assembling $DB_DEBUG"
rm -f "$DB_DEBUG"
sqlite3 "$DB_DEBUG" <"$SCHEMA_DEBUG"
import_csv "$DB_DEBUG" dictionary "$EXPORT_DEBUG/dictionary.csv"
import_csv "$DB_DEBUG" deletes "$EXPORT_DEBUG/deletes.csv"
import_csv "$DB_DEBUG" bigrams "$EXPORT_DEBUG/bigrams.csv"
import_csv "$DB_DEBUG" trigrams "$EXPORT_DEBUG/trigrams.csv"
sqlite3 "$DB_DEBUG" "VACUUM; ANALYZE;"

echo "Wrote $DB_DEBUG"
sqlite3 "$DB_DEBUG" <<'SQL'
SELECT 'dictionary', COUNT(*) FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams;
SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
FROM pragma_page_count(), pragma_page_size();
SQL

# --------------------------------------------------------------------------
# spell.db — id-keyed product (export_id/)
# --------------------------------------------------------------------------
need_file "$EXPORT_ID/dictionary.csv" "run: zig build export"
need_file "$EXPORT_ID/bigrams.csv" "run: zig build export"
need_file "$EXPORT_ID/trigrams.csv" "run: zig build export"
need_file "$SEED" "shipped confusion seed missing"

if ! head -n1 "$EXPORT_ID/dictionary.csv" | grep -q '^id,'; then
  echo "error: export_id/dictionary.csv must start with id,word,frequency (got: $(head -n1 "$EXPORT_ID/dictionary.csv"))" >&2
  exit 1
fi

echo "==> SymSpell deletes (word_id) from export_id/dictionary.csv"
run_data --symspell-deletes "$EXPORT_ID/dictionary.csv"
mv -f "$ROOT/deletes.csv" "$EXPORT_ID/deletes.csv"

echo "==> Mining confusion weights"
run_data --mine-confusions "$EXPORT_ID/dictionary.csv" "$SEED"
mv -f "$ROOT/confusions.csv" "$EXPORT_ID/confusions.csv"
if [[ -f "$ROOT/confusions_mined.csv" ]]; then
  mv -f "$ROOT/confusions_mined.csv" "$EXPORT_ID/confusions_mined.csv"
fi

echo "==> Assembling $DB_ID"
rm -f "$DB_ID"
sqlite3 "$DB_ID" <"$SCHEMA_ID"
import_csv "$DB_ID" dictionary "$EXPORT_ID/dictionary.csv"
import_csv "$DB_ID" deletes "$EXPORT_ID/deletes.csv"
import_csv "$DB_ID" bigrams "$EXPORT_ID/bigrams.csv"
import_csv "$DB_ID" trigrams "$EXPORT_ID/trigrams.csv"
import_csv "$DB_ID" confusions "$EXPORT_ID/confusions.csv"
sqlite3 "$DB_ID" "VACUUM; ANALYZE;"

rm -f "$ROOT/spell_id.db"
ln -s "$(basename "$DB_ID")" "$ROOT/spell_id.db"

echo "Wrote $DB_ID (and spell_id.db → spell.db)"
sqlite3 "$DB_ID" <<'SQL'
SELECT 'dictionary', COUNT(*) FROM dictionary
UNION ALL SELECT 'deletes', COUNT(*) FROM deletes
UNION ALL SELECT 'bigrams', COUNT(*) FROM bigrams
UNION ALL SELECT 'trigrams', COUNT(*) FROM trigrams
UNION ALL SELECT 'confusions', COUNT(*) FROM confusions;
SELECT ROUND(page_count * page_size / 1024.0 / 1024.0, 1) AS db_mb
FROM pragma_page_count(), pragma_page_size();
SQL

echo "==> prepare done"
