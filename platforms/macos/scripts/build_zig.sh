#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build the Zig transliteration engine and stage a linkable object.
#
# Xcode's Frameworks phase links build/zig/byakaron_zcu.o directly, so this must
# run before the link step. It is wired in as a "Run Script" build phase on the
# Byakaron Keyboard target (the app's dependency, which builds first) and is also
# safe to call directly (e.g. from scripts/build.sh or by hand).
#
# The Zig 0.17-dev archiver emits non-8-byte-aligned mach-o members that ld
# rejects; extracting the archive with the system `ar` yields aligned objects.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"        # platforms/macos
ZIG_REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"  # repo root
BUILD_DIR="$PROJECT_ROOT/build"
ZIG_LIB_DIR="$BUILD_DIR/zig"

# Xcode run-script phases get a minimal PATH that usually lacks Homebrew and
# version-manager shims (zig here is an asdf shim). Make sure we can find it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.asdf/shims:$PATH"
if ! command -v zig >/dev/null 2>&1; then
    echo "error: could not find the 'zig' executable on PATH" >&2
    exit 1
fi

# Optimize mode follows Xcode's CONFIGURATION when present, else ReleaseFast.
ZIG_OPTIMIZE="ReleaseFast"
case "${CONFIGURATION:-}" in
    *Debug*) ZIG_OPTIMIZE="Debug" ;;
esac

echo ">>> Building Zig engine (libbyakaron, $ZIG_OPTIMIZE)..."
( cd "$ZIG_REPO_ROOT" && zig build -Doptimize="$ZIG_OPTIMIZE" -Dtarget=aarch64-macos )

rm -rf "$ZIG_LIB_DIR" && mkdir -p "$ZIG_LIB_DIR"
(
    cd "$ZIG_LIB_DIR"
    ar x "$ZIG_REPO_ROOT/zig-out/lib/libbyakaron.a"
    chmod 644 ./*.o
    rm -f libbyakaron.a
    ar rcs libbyakaron.a ./*.o
)
echo ">>> Zig objects staged in: $ZIG_LIB_DIR"
