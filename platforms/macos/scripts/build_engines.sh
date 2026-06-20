#!/bin/bash
# Build the native engines the Xcode target links against, into a stable,
# arch-agnostic staging dir ($PROJECT_DIR/build/xcode-libs):
#
#   • libavrobangla_engine.a  — Rust/riti engine (built with cargo)
#   • libbyakaron.a           — Zig transliteration engine (built with zig)
#   • byakaron.h              — Zig FFI header (copied for HEADER_SEARCH_PATHS)
#
# Run as a pre-compile "Run Script" build phase so the libs exist before swiftc
# links. The Zig archive is re-packed with the system `ar` because the Zig
# 0.17-dev archiver emits non-8-byte-aligned mach-o members that ld rejects.
set -euo pipefail

# PROJECT_DIR is set by Xcode; fall back to this script's grandparent otherwise.
MACOS_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO_ROOT="$(cd "$MACOS_DIR/../.." && pwd)"
ENGINE_DIR="$MACOS_DIR/engine"
STAGE_DIR="$MACOS_DIR/build/xcode-libs"

# Xcode's CONFIGURATION is "Debug"/"Release"; map to cargo/zig profiles.
CONFIG="${CONFIGURATION:-Debug}"
if [ "$CONFIG" = "Release" ]; then
    CARGO_PROFILE_DIR="release"; CARGO_ARGS="--release"; ZIG_OPT="ReleaseFast"
else
    CARGO_PROFILE_DIR="debug"; CARGO_ARGS=""; ZIG_OPT="Debug"
fi

mkdir -p "$STAGE_DIR"

# Make sure cargo/zig are reachable when Xcode runs with a minimal PATH.
export PATH="$HOME/.cargo/bin:$HOME/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v cargo >/dev/null || { source "$HOME/.cargo/env" 2>/dev/null || true; }

echo "note: building Rust engine ($CONFIG)"
( cd "$ENGINE_DIR" && cargo build $CARGO_ARGS --target aarch64-apple-darwin )
cp "$ENGINE_DIR/target/aarch64-apple-darwin/$CARGO_PROFILE_DIR/libavrobangla_engine.a" \
   "$STAGE_DIR/libavrobangla_engine.a"

echo "note: building Zig engine ($CONFIG)"
( cd "$REPO_ROOT" && zig build -Doptimize="$ZIG_OPT" -Dtarget=aarch64-macos )
cp "$REPO_ROOT/zig-out/include/byakaron.h" "$STAGE_DIR/byakaron.h"

# Re-archive the Zig static lib so ld accepts the member alignment.
REPACK="$(mktemp -d)"
trap 'rm -rf "$REPACK"' EXIT
( cd "$REPACK" && ar x "$REPO_ROOT/zig-out/lib/libbyakaron.a" && chmod 644 ./*.o && ar rcs "$STAGE_DIR/libbyakaron.a" ./*.o )

echo "note: engines staged in $STAGE_DIR"
