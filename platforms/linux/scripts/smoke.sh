#!/bin/bash
set -euo pipefail

# Build libbyakaron.so (via build_zig.sh) and run the C ABI smoke test against it.
#
#     bash platforms/linux/scripts/smoke.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"

bash "$SCRIPT_DIR/build_zig.sh"

mkdir -p "$BUILD_DIR/bin"
echo ">>> Compiling smoke test..."
# Core/autocomplete.c is compiled in (not just linked against the .so) because
# the test covers its JSON parser directly. That pulls in glib, which is a
# dependency of the Core glue rather than of libbyakaron itself.
cc -O2 -Wall -Wextra -o "$BUILD_DIR/bin/smoke" \
    "$PROJECT_ROOT/tests/smoke.c" \
    "$PROJECT_ROOT/Core/autocomplete.c" \
    "$PROJECT_ROOT/Core/spell.c" \
    -I"$BUILD_DIR/include" -I"$PROJECT_ROOT/Core" \
    $(pkg-config --cflags glib-2.0) \
    -L"$BUILD_DIR/lib" -lbyakaron \
    $(pkg-config --libs glib-2.0) \
    -Wl,-rpath,"$BUILD_DIR/lib"

SPELL_DB="${BYAKARON_SPELL_DB:-$PROJECT_ROOT/../../packages/data/spell.db}"
if [[ -f "$SPELL_DB" ]]; then
    export BYAKARON_SPELL_DB="$SPELL_DB"
else
    echo "note: $SPELL_DB missing — spell-check assertions will be skipped"
fi

echo ">>> Running..."
echo
exec "$BUILD_DIR/bin/smoke"
