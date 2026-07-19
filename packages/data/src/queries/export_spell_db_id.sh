#!/usr/bin/env bash
# Thin wrapper — prefer: zig build prepare
# ID-keyed product DB only (legacy name spell_id.db). Full assemble: prepare_spell_dbs.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_DIR="${1:-$ROOT/export_id}"
DB_PATH="${2:-$ROOT/spell.db}"

if [[ "$EXPORT_DIR" != "$ROOT/export_id" || ( "$DB_PATH" != "$ROOT/spell.db" && "$DB_PATH" != "$ROOT/spell_id.db" ) ]]; then
  echo "note: custom paths are no longer supported here; use prepare_spell_dbs.sh" >&2
fi

exec "$ROOT/src/queries/prepare_spell_dbs.sh" "${DATA_EXE:-$ROOT/zig-out/bin/data}"
