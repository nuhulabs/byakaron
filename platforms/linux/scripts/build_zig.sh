#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build the Zig engine as a shared library and stage it for the Linux port.
#
# Linux uses the SHARED library (unlike macOS, which links extracted static
# objects into the Xcode targets) because two separate processes consume it —
# the IBus engine and the GTK app — and both should share one mapped copy.
#
# Outputs into platforms/linux/build/:
#     lib/libbyakaron.so
#     include/byakaron.h
#     share/spell.db          (only when packages/data/spell.db has been built)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"        # platforms/linux
ZIG_REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"  # repo root
BUILD_DIR="$PROJECT_ROOT/build"

ZIG_OPTIMIZE="${ZIG_OPTIMIZE:-ReleaseFast}"

# Editors and IDE build phases hand us a minimal PATH; pick up a user-local Zig.
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
ZIG="${ZIG_EXE:-$(command -v zig || true)}"
if [[ -z "$ZIG" ]]; then
    echo "error: could not find the 'zig' executable on PATH" >&2
    echo "       this branch needs 0.17.0-dev.1422+e863bf3be — see platforms/linux/README.md" >&2
    exit 1
fi

echo ">>> zig: $ZIG ($("$ZIG" version))"
echo ">>> Building Zig engine (libbyakaron.so, $ZIG_OPTIMIZE)..."
( cd "$ZIG_REPO_ROOT" && "$ZIG" build -Dshared=true -Doptimize="$ZIG_OPTIMIZE" )

SO="$ZIG_REPO_ROOT/zig-out/lib/libbyakaron.so"
HDR="$ZIG_REPO_ROOT/zig-out/include/byakaron.h"
[[ -f "$SO"  ]] || { echo "error: $SO not produced" >&2; exit 1; }
[[ -f "$HDR" ]] || { echo "error: $HDR not produced" >&2; exit 1; }

rm -rf "$BUILD_DIR/lib" "$BUILD_DIR/include"
mkdir -p "$BUILD_DIR/lib" "$BUILD_DIR/include" "$BUILD_DIR/share"
cp "$SO"  "$BUILD_DIR/lib/"
cp "$HDR" "$BUILD_DIR/include/"
echo ">>> Staged: $BUILD_DIR/lib/libbyakaron.so"

# spell.db is generated, not committed. Build it with:
#     bash platforms/linux/scripts/prepare_spell_db.sh
# The engine types without it; only spell-check needs it.
SPELL_DB="$ZIG_REPO_ROOT/packages/data/spell.db"
if [[ -f "$SPELL_DB" ]]; then
    cp "$SPELL_DB" "$BUILD_DIR/share/spell.db"
    echo ">>> Staged: $BUILD_DIR/share/spell.db"
else
    echo "note: packages/data/spell.db not built yet — spell-check will be unavailable"
fi
