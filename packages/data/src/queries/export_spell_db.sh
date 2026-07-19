#!/usr/bin/env bash
# Thin wrapper — prefer: zig build prepare
# Text-keyed debug DB only (legacy). Full assemble: prepare_spell_dbs.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORT_DIR="${1:-$ROOT/export}"
DB_PATH="${2:-$ROOT/spell_debug.db}"

if [[ "$EXPORT_DIR" != "$ROOT/export" || "$DB_PATH" != "$ROOT/spell_debug.db" ]]; then
  echo "note: custom paths are no longer supported here; use prepare_spell_dbs.sh" >&2
fi

exec "$ROOT/src/queries/prepare_spell_dbs.sh" "${DATA_EXE:-$ROOT/zig-out/bin/data}"
