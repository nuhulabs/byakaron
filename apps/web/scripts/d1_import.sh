#!/usr/bin/env bash
# Import spell.db (built by `zig build db`) into the web app's Cloudflare D1
# database (binding `DB` in apps/web/wrangler.jsonc).
#
#   apps/web/scripts/d1_import.sh [options] [path/to/spell.db]
#
#   --remote          import into the deployed D1 database (default)
#   --local           import into wrangler's local D1 (for `wrangler dev`)
#   --persist-to DIR  local D1 state directory (with --local)
#   --dump-only       only write the SQL chunks, don't run wrangler
#   --from N          resume: skip chunks before N (chunk 0 drops + recreates)
#   --out DIR         chunk directory (default: zig-out/d1)
#   --rows N          rows per INSERT statement (default 400)
#   --chunk-mb N      max size of one chunk file in MB (default 50)
#
# The dump is a fixed sequence of files run in order:
#   0000-schema.sql   DROP TABLE IF EXISTS + CREATE TABLE (no indexes)
#   0001..N-data.sql  multi-row INSERTs, one statement per line, each well under
#                     D1's 100 KB statement limit
#   last-indexes.sql  CREATE INDEX, once the data is in
# so a rerun from chunk 0 always rebuilds the database from scratch.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
web="$root/apps/web"

mode=--remote
persist=()
dump_only=0
from=0
out="$root/zig-out/d1"
rows=400
chunk_mb=50
db="$root/zig-out/db/spell.db"

while [ $# -gt 0 ]; do
  case "$1" in
    --remote | --local) mode="$1" ;;
    --persist-to) persist=(--persist-to "$2"); shift ;;
    --dump-only) dump_only=1 ;;
    --from) from="$2"; shift ;;
    --out) out="$2"; shift ;;
    --rows) rows="$2"; shift ;;
    --chunk-mb) chunk_mb="$2"; shift ;;
    -h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "d1_import: unknown option $1" >&2; exit 2 ;;
    *) db="$1" ;;
  esac
  shift
done

[ -f "$db" ] || { echo "d1_import: $db not found; run \`zig build db\`" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "d1_import: sqlite3 not found" >&2; exit 1; }

q() { sqlite3 -batch -noheader "$db" "$@"; }

# Application tables only; sqlite_* (e.g. sqlite_stat1) are SQLite internals D1 manages.
tables=$(q "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")

dump() {
  rm -rf "$out"
  mkdir -p "$out"

  {
    for t in $tables; do echo "DROP TABLE IF EXISTS \"$t\";"; done
    q "SELECT sql || ';' FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  } >"$out/0000-schema.sql"

  # One INSERT per `rows` rowids. Text containing a newline would split a
  # statement across lines (chunks are cut on line boundaries), so refuse it.
  local data="$out/data.sql"
  : >"$data"
  for t in $tables; do
    local cols nl
    cols=$(q "SELECT group_concat('quote(\"' || name || '\")', ' || '','' || ') FROM pragma_table_info('$t')")
    nl=$(q "SELECT group_concat('instr(\"' || name || '\", char(10))', ' OR ') FROM pragma_table_info('$t') WHERE type = 'TEXT'")
    if [ -n "$nl" ] && [ "$(q "SELECT count(*) FROM \"$t\" WHERE $nl")" != 0 ]; then
      echo "d1_import: $t has text with newlines" >&2; exit 1
    fi
    echo "  dumping $t ($(q "SELECT count(*) FROM \"$t\"") rows)" >&2
    q "SELECT 'INSERT INTO \"$t\" VALUES ' || group_concat('(' || $cols || ')', ',') || ';'
       FROM \"$t\" GROUP BY (rowid - 1) / $rows" >>"$data"
  done

  local longest
  longest=$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$data")
  if [ "$longest" -ge 100000 ]; then
    echo "d1_import: a statement is $longest bytes (D1 max 100000); lower --rows" >&2; exit 1
  fi

  LC_ALL=C awk -v dir="$out" -v max=$((chunk_mb * 1024 * 1024)) '
    BEGIN { n = 1; size = 0; file = sprintf("%s/%04d-data.sql", dir, n) }
    {
      if (size > 0 && size + length($0) + 1 > max) {
        close(file); n++; size = 0; file = sprintf("%s/%04d-data.sql", dir, n)
      }
      print > file; size += length($0) + 1
    }' "$data"
  rm "$data"

  local last
  last=$(ls "$out" | grep -c -- '-data.sql$')
  q "SELECT sql || ';' FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name" \
    >"$out/$(printf %04d $((last + 1)))-indexes.sql"

  echo "  $(ls "$out" | wc -l | tr -d ' ') files, $(du -sh "$out" | cut -f1), longest statement $longest bytes" >&2
}

start=$(date +%s)
if [ "$from" = 0 ] || [ ! -d "$out" ]; then
  echo "d1_import: dumping $db → $out" >&2
  dump
  echo "d1_import: dump took $(($(date +%s) - start))s" >&2
fi
[ "$dump_only" = 1 ] && exit 0

i=0
for f in "$out"/*.sql; do
  if [ "$i" -ge "$from" ]; then
    echo "d1_import: [$i] $(basename "$f") ($(du -h "$f" | cut -f1))" >&2
    t0=$(date +%s)
    (cd "$web" && npx --yes wrangler@4.100.0 d1 execute DB "$mode" ${persist[@]+"${persist[@]}"} --yes --file "$f" >/dev/null) || {
      echo "d1_import: chunk $i failed; resume with --from $i" >&2
      exit 1
    }
    echo "d1_import: [$i] done in $(($(date +%s) - t0))s" >&2
  fi
  i=$((i + 1))
done
echo "d1_import: $mode import finished in $(($(date +%s) - start))s" >&2
