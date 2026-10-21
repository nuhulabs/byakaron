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
ZIG_OBJ_DIR="$BUILD_DIR/zig"

# Xcode run-script phases get a minimal PATH that usually lacks Homebrew and
# version-manager shims (zig here is an asdf shim pinned by .tool-versions).
export PATH="$PATH:$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin"
if ! command -v zig >/dev/null 2>&1; then
    echo "error: could not find the 'zig' executable on PATH" >&2
    exit 1
fi

# Always ReleaseFast for the embedded engine: Zig Debug compiles sqlite3.c with
# UBSan instrumentation, and Xcode's linker does not provide those runtime symbols.
ZIG_OPTIMIZE="ReleaseFast"

echo ">>> Building Zig engine (libbyakaron, $ZIG_OPTIMIZE)..."
( cd "$ZIG_REPO_ROOT" && zig build lib -Doptimize="$ZIG_OPTIMIZE" -Dtarget=aarch64-macos )

rm -rf "$ZIG_OBJ_DIR" && mkdir -p "$ZIG_OBJ_DIR"
(
    cd "$ZIG_OBJ_DIR"
    ar x "$ZIG_REPO_ROOT/zig-out/lib/libbyakaron.a"
    chmod 644 ./*.o
    rm -f libbyakaron.a
    ar rcs libbyakaron.a ./*.o
)
echo ">>> Zig objects staged in: $ZIG_OBJ_DIR"

# Avro Dictionary.json (SpellServer.swift) is generated from OmicronLab's iAvro
# database by `zig build lib`, which installs it. Stage it before Xcode's Copy Bundle Resources phase.
AVRO_DICT="$ZIG_REPO_ROOT/zig-out/db/Dictionary.json"
cp "$AVRO_DICT" "$PROJECT_ROOT/Resources/Dictionary.json"
echo ">>> Staged Dictionary.json -> $PROJECT_ROOT/Resources/Dictionary.json"

# Stage spell.db into Resources (APFS clone / hardlink when possible) so the
# Swift SpellEngine can open it from the app/IME bundle.
SPELL_DB="$ZIG_REPO_ROOT/zig-out/db/spell.db"  # `zig build db`
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
    echo "warning: spell.db not found at $SPELL_DB (run: zig build db)" >&2
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
