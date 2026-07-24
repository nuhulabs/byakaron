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
ZIG_CURSOR="$HOME/Library/Application Support/Cursor/User/globalStorage/ziglang.vscode-zig/zig/aarch64-macos-0.17.0-dev.1422+e863bf3be"
export PATH="$ZIG_CURSOR:/opt/homebrew/bin:/usr/local/bin:$HOME/.asdf/shims:$PATH"
if ! command -v zig >/dev/null 2>&1; then
    echo "error: could not find the 'zig' executable on PATH" >&2
    exit 1
fi

# Always ReleaseFast for the embedded engine: Zig Debug compiles sqlite3.c with
# UBSan instrumentation, and Xcode's linker does not provide those runtime symbols.
ZIG_OPTIMIZE="ReleaseFast"

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

# Stage spell.db into Resources (APFS clone / hardlink when possible) so the
# Swift SpellEngine can open it from the app/IME bundle.
SPELL_DB="$ZIG_REPO_ROOT/packages/data/spell.db"
STAGE_DB="$PROJECT_ROOT/Resources/spell.db"
if [[ -f "$SPELL_DB" ]]; then
    if [[ ! -e "$STAGE_DB" ]] || [[ "$SPELL_DB" -nt "$STAGE_DB" ]]; then
        rm -f "$STAGE_DB"
        if cp -c "$SPELL_DB" "$STAGE_DB" 2>/dev/null; then
            :
        elif ln "$SPELL_DB" "$STAGE_DB" 2>/dev/null; then
            :
        else
            cp "$SPELL_DB" "$STAGE_DB"
        fi
        echo ">>> Staged spell.db -> $STAGE_DB"
    fi
else
    echo "warning: spell.db not found at $SPELL_DB" >&2
fi

# When Xcode invokes this script, also drop spell.db into the product Resources.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" && -f "$SPELL_DB" ]]; then
    DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/spell.db"
    mkdir -p "$(dirname "$DEST")"
    if cp -c "$SPELL_DB" "$DEST" 2>/dev/null; then
        :
    elif ln "$SPELL_DB" "$DEST" 2>/dev/null; then
        :
    else
        cp "$SPELL_DB" "$DEST"
    fi
    echo ">>> Embedded spell.db -> $DEST"
fi
