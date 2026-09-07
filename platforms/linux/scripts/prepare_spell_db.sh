#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build packages/data/spell.db from the Avro lexicon already in the repo.
#
#     bash platforms/linux/scripts/prepare_spell_db.sh
#
# The Wikipedia corpus (word_triplets.csv) is not in git. The candidate window
# already uses src/assets/dictionary_macos_sorted.txt (~159k lemmas); this
# script turns that same list into a local SQLite file the engine opens with
# byakaron_spell_create. Bigram/trigram tables stay empty until a Wikipedia
# export exists; lookups and SymSpell suggestions still work.
#
# Assembles the DB with Python's stdlib sqlite3 so we do not need the sqlite3
# CLI (or sudo) on the box.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
DATA="$REPO_ROOT/packages/data"
LEXICON="$REPO_ROOT/src/assets/dictionary_macos_sorted.txt"
SCHEMA="$DATA/src/queries/10_sqlite_schema_id.sql"
SEED="$DATA/src/queries/confusions_seed.csv"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

[[ -f "$LEXICON" ]] || { echo "error: missing $LEXICON" >&2; exit 1; }
[[ -f "$SCHEMA" ]]  || { echo "error: missing $SCHEMA" >&2; exit 1; }
[[ -f "$SEED" ]]    || { echo "error: missing $SEED" >&2; exit 1; }

echo ">>> lexicon: $LEXICON ($(wc -l < "$LEXICON") words)"

{
    echo "word"
    cat "$LEXICON"
} > "$DATA/dictionary_macos.csv"

mkdir -p "$DATA/export_id"

# id,word,frequency — Avro lemmas at frequency 1 (same as prepare.zig's merge).
python3 - "$LEXICON" "$DATA/export_id/dictionary_prepared.csv" <<'PY'
import sys
src, dest = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as inf, open(dest, "w", encoding="utf-8") as out:
    out.write("id,word,frequency\n")
    n = 0
    for line in inf:
        word = line.strip()
        if not word:
            continue
        n += 1
        if "," in word or '"' in word:
            word = '"' + word.replace('"', '""') + '"'
        out.write(f"{n},{word},1\n")
print(f"    {n} words")
PY

printf 'w1_id,w2_id,frequency\n' > "$DATA/export_id/bigrams.csv"
printf 'w1_id,w2_id,w3_id,frequency\n' > "$DATA/export_id/trigrams.csv"
# prepare.zig also wants a wiki dictionary.csv; unused once we hand it prepared.
printf 'id,word,frequency\n' > "$DATA/export_id/dictionary.csv"
echo ">>> wrote $DATA/export_id/"

echo ">>> building packages/data tools..."
( cd "$DATA" && zig build )

DATA_EXE="$DATA/zig-out/bin/data"
[[ -x "$DATA_EXE" ]] || { echo "error: $DATA_EXE missing" >&2; exit 1; }

echo ">>> SymSpell deletes (this is the slow step)..."
( cd "$DATA" && "$DATA_EXE" --symspell-deletes export_id/dictionary_prepared.csv )
mv -f "$DATA/deletes.csv" "$DATA/export_id/deletes.csv"

echo ">>> mine confusion weights..."
( cd "$DATA" && "$DATA_EXE" --mine-confusions export_id/dictionary_prepared.csv src/queries/confusions_seed.csv )
mv -f "$DATA/confusions.csv" "$DATA/export_id/confusions.csv"
rm -f "$DATA/confusions_mined.csv"

echo ">>> assemble spell.db (Python sqlite3)..."
python3 - "$DATA" <<'PY'
import csv, sqlite3, sys
from pathlib import Path

data = Path(sys.argv[1])
schema = (data / "src/queries/10_sqlite_schema_id.sql").read_text(encoding="utf-8")
db_path = data / "spell.db"
export = data / "export_id"

if db_path.exists():
    db_path.unlink()

con = sqlite3.connect(db_path)
con.executescript(schema)

def import_csv(table, path, expected):
    with path.open(encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header != expected:
            raise SystemExit(f"{path.name}: got {header}, expected {expected}")
        rows = list(reader)
    placeholders = ",".join("?" * len(expected))
    con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
    print(f"    {table}: {len(rows)}")

import_csv("dictionary", export / "dictionary_prepared.csv", ["id", "word", "frequency"])
import_csv("deletes", export / "deletes.csv", ["delete_key", "word_id"])
import_csv("bigrams", export / "bigrams.csv", ["w1_id", "w2_id", "frequency"])
import_csv("trigrams", export / "trigrams.csv", ["w1_id", "w2_id", "w3_id", "frequency"])
import_csv("confusions", export / "confusions.csv", ["from_g", "to_g", "weight", "kind"])

con.commit()
con.execute("VACUUM")
con.execute("ANALYZE")
con.commit()
con.close()
print("    vacuum/analyze done")
PY

[[ -f "$DATA/spell.db" ]] || { echo "error: spell.db was not produced" >&2; exit 1; }
echo
echo "=== $DATA/spell.db ($(du -h "$DATA/spell.db" | cut -f1)) ==="
