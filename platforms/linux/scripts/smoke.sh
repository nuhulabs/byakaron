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
cc -O2 -Wall -Wextra -o "$BUILD_DIR/bin/smoke" "$PROJECT_ROOT/tests/smoke.c" \
    -I"$BUILD_DIR/include" \
    -L"$BUILD_DIR/lib" -lbyakaron \
    -Wl,-rpath,"$BUILD_DIR/lib"

echo ">>> Running..."
echo
exec "$BUILD_DIR/bin/smoke"
