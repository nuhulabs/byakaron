#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Byakaron build script
#
# This is now a thin wrapper around `xcodebuild`: Xcode owns everything — the
# app + embedded keyboard build, code signing, Info.plist generation, the embed
# (CopyFiles) step, and even the Zig engine (a "Build Zig engine" run-script
# phase on the keyboard target runs scripts/build_zig.sh before linking).
#
# Usage:
#   ./scripts/build.sh [release|debug]
#   SANDBOX=1 ./scripts/build.sh        # sandboxed app variant
# ---------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # apps/macos
BUILD_DIR="$PROJECT_ROOT/build"
DERIVED_DIR="$BUILD_DIR/DerivedData"
APP_NAME="Byakaron"
SCHEME="Byakaron"

BUILD_TYPE="${1:-release}"
BUILD_UNIVERSAL="${2:-false}"

# Configuration selection:
#   • Default        -> Release           (non-sandboxed, auto-installs keyboard)
#   • debug arg      -> Debug
#   • SANDBOX=1      -> Release-Sandboxed  (sandboxed app, manual keyboard install)
# The keyboard helper is always unsandboxed (it runs as a system IME).
CONFIG="Release"
[ "$BUILD_TYPE" = "debug" ] && CONFIG="Debug"
if [ "${SANDBOX:-0}" = "1" ]; then
    CONFIG="Release-Sandboxed"
fi

echo "=== Byakaron Build ==="
echo "Build type:    $BUILD_TYPE"
echo "Configuration: $CONFIG"
echo ""

# arm64-only: both products require the macOS 26 SDK and target arm64-macos.
if [ "$BUILD_UNIVERSAL" = "true" ]; then
    echo ">>> WARNING: universal build is not supported; building arm64 only."
    BUILD_UNIVERSAL="false"
fi

# ---------------------------------------------------------------------------
# Build Byakaron.app (with the embedded keyboard) via xcodebuild.
#
# The Zig engine is built by the keyboard target's "Build Zig engine" run-script
# phase (scripts/build_zig.sh), so there is nothing to compile by hand here.
#
# Signed ad-hoc ("-") so the result installs/runs locally without a developer
# cert. Each target's entitlements come from its CODE_SIGN_ENTITLEMENTS build
# setting, so the inner keyboard stays unsandboxed while the app honors the
# selected (sandboxed / non-sandboxed) configuration.
# ---------------------------------------------------------------------------
echo ">>> Building $APP_NAME.app via xcodebuild ($CONFIG)..."
xcodebuild \
    -project "$PROJECT_ROOT/Byakaron.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DIR" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build

# ---------------------------------------------------------------------------
# Stage the product at build/Byakaron.app so install.sh / create_dmg.sh keep
# working unchanged.
# ---------------------------------------------------------------------------
PRODUCT_APP="$DERIVED_DIR/Build/Products/$CONFIG/$APP_NAME.app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
cp -R "$PRODUCT_APP" "$APP_BUNDLE"

echo ""
echo "=== Build complete ==="
echo "App bundle:   $APP_BUNDLE"
echo "Embedded IME: $APP_BUNDLE/Contents/Library/InputMethods/$APP_NAME Keyboard.app"
echo ""
echo "To install, run: ./scripts/install.sh"
