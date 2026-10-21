#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build the IBus engine and register it with the *running* ibus-daemon, without
# installing anything into /usr.
#
#     bash apps/linux/scripts/dev_run.sh
#
# The registration lives only as long as this process, so Ctrl-C removes it
# again. scripts/install.sh is the permanent counterpart (Day 3).
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"        # apps/linux
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
ZIG="${ZIG_EXE:-$(command -v zig || true)}"
if [[ -z "$ZIG" ]]; then
    echo "error: no 'zig' on PATH — see apps/linux/README.md" >&2
    exit 1
fi

if [[ -z "${BYAKARON_SPELL_DB:-}" && -f "$REPO_ROOT/zig-out/db/spell.db" ]]; then
    export BYAKARON_SPELL_DB="$REPO_ROOT/zig-out/db/spell.db"
fi

echo ">>> Building byakaron-ibus..."
( cd "$REPO_ROOT" && "$ZIG" build linux -Doptimize="${ZIG_OPTIMIZE:-ReleaseFast}" )

BIN="$REPO_ROOT/zig-out/bin/byakaron-ibus"
[[ -x "$BIN" ]] || { echo "error: $BIN missing" >&2; exit 1; }

# Fill in the component template with this checkout's absolute paths.
mkdir -p "$BUILD_DIR"
XML="$BUILD_DIR/byakaron.xml"
sed -e "s|@BYK_EXEC@|$BIN|g" \
    -e "s|@BYK_ICON@|input-keyboard|g" \
    -e "s|@BYK_SETUP@||g" \
    "$PROJECT_ROOT/Resources/byakaron.xml.in" > "$XML"
echo ">>> Component XML: $XML"

if ! pgrep -x ibus-daemon >/dev/null; then
    echo "error: ibus-daemon is not running — start it with 'ibus-daemon -drx'" >&2
    exit 1
fi

SCHEMA_DIR="$REPO_ROOT/zig-out/share/glib-2.0/schemas"
if [[ -f "$SCHEMA_DIR/gschemas.compiled" ]]; then
    export GSETTINGS_SCHEMA_DIR="$SCHEMA_DIR"
fi

echo ">>> Registering with ibus-daemon (Ctrl-C to unregister and exit)"
echo
exec "$BIN" --xml "$XML"
