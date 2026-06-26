#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/Byakaron"           # unified source tree
RES_DIR="$SRC_DIR/Resources"               # shared Info plists, icons, entitlements
BUILD_DIR="$PROJECT_ROOT/build"

# Final shippable product: Byakaron.app (SwiftUI app) embedding the IME helper.
APP_NAME="Byakaron"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Embedded IME helper. Bundle + executable are user-facing as "Byakaron Keyboard";
# the Swift MODULE name stays "Byakaron" so the Info.plist
# InputMethodServerControllerClass "Byakaron.ByakaronInputController" resolves.
IME_NAME="Byakaron Keyboard"
IME_BUNDLE="$BUILD_DIR/$IME_NAME.app"

# Parse arguments
BUILD_TYPE="${1:-release}"
BUILD_UNIVERSAL="${2:-false}"

echo "=== Byakaron Build ==="
echo "Build type: $BUILD_TYPE"
echo "Universal binary: $BUILD_UNIVERSAL"
echo ""

# NOTE: Both products require the macOS 26 SDK and target arm64-apple-macos26.0,
# so universal (lipo) builds are not supported. If requested, warn and fall back.
if [ "$BUILD_UNIVERSAL" = "true" ]; then
    echo ">>> WARNING: universal build is not supported for Byakaron.app."
    echo ">>>          Falling back to arm64-only release build."
    BUILD_UNIVERSAL="false"
fi

MACOS26_SDK="$(xcrun --sdk macosx26.5 --show-sdk-path)"
TARGET="arm64-apple-macos26.0"


# ---------------------------------------------------------------------------
# Step 1b: Build the Zig transliteration library (libbyakaron.a) from the repo
# root and re-archive it so the macOS linker accepts it.
#
# The Zig 0.17-dev archiver emits non-8-byte-aligned mach-o members that ld
# rejects ("not 8-byte aligned"); re-packing the extracted objects with the
# system `ar` fixes the alignment. The repacked lib + installed header land in
# $ZIG_LIB_DIR / $ZIG_INCLUDE_DIR for swiftc to link against.
# ---------------------------------------------------------------------------
echo ">>> Building Zig engine (libbyakaron)..."
ZIG_REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"   # platforms/macos -> repo root
ZIG_OPTIMIZE="ReleaseFast"
[ "$BUILD_TYPE" = "debug" ] && ZIG_OPTIMIZE="Debug"

( cd "$ZIG_REPO_ROOT" && zig build -Doptimize="$ZIG_OPTIMIZE" -Dtarget=aarch64-macos )

ZIG_LIB_DIR="$BUILD_DIR/zig"
ZIG_INCLUDE_DIR="$ZIG_REPO_ROOT/zig-out/include"
rm -rf "$ZIG_LIB_DIR" && mkdir -p "$ZIG_LIB_DIR"
(
    cd "$ZIG_LIB_DIR"
    ar x "$ZIG_REPO_ROOT/zig-out/lib/libbyakaron.a"
    chmod 644 ./*.o
    rm -f libbyakaron.a
    ar rcs libbyakaron.a ./*.o
)
echo ">>> Zig library built: $ZIG_LIB_DIR/libbyakaron.a"

# Both header dirs are passed to swiftc (unquoted -> word-split into -I flags);
# BridgeHeader.h includes both avrobangla_engine.h and byakaron.h.
HEADER_SEARCH_PATH="-I $ZIG_INCLUDE_DIR"

# ---------------------------------------------------------------------------
# Step 2: Build the embedded IME helper -> "Byakaron Keyboard.app"
#   Sources: IME/, Keyboard/, Core/Settings, Core/Transliteration bridge.
# ---------------------------------------------------------------------------
echo ">>> Building embedded IME ($IME_NAME.app)..."
rm -rf "$IME_BUNDLE"
mkdir -p "$IME_BUNDLE/Contents/MacOS"
mkdir -p "$IME_BUNDLE/Contents/Resources/data"

cp "$RES_DIR/Info-keyboard.plist" "$IME_BUNDLE/Contents/Info.plist"
cp "$RES_DIR/iconTemplate.pdf"    "$IME_BUNDLE/Contents/Resources/iconTemplate.pdf"
cp "$RES_DIR/AppIcon.icns"        "$IME_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/data/"*.json    "$IME_BUNDLE/Contents/Resources/data/"
echo -n "APPL????" > "$IME_BUNDLE/Contents/PkgInfo"

IME_SOURCES=(
    "$SRC_DIR/Keyboard/Controller/main.swift"
    "$SRC_DIR/Keyboard/Controller/AppDelegate.swift"
    "$SRC_DIR/Keyboard/CandidateUI/CandidatePanel.swift"
    "$SRC_DIR/Keyboard/Activation/SpellServer.swift"
    "$SRC_DIR/Keyboard/Phonetic/PhoneticInputController.swift"
    "$SRC_DIR/Keyboard/Phonetic/PhoneticInputController+Zig.swift"
    "$SRC_DIR/Keyboard/Phonetic/PhoneticDictionary.swift"
    "$SRC_DIR/Core/Transliteration/ZigTransliterator.swift"
    "$SRC_DIR/Core/Settings/ByakaronSettings.swift"
)

swiftc "${IME_SOURCES[@]}" \
    -O \
    -module-name "Byakaron" \
    -import-objc-header "$SRC_DIR/Core/Transliteration/BridgeHeader.h" \
    $HEADER_SEARCH_PATH \
    -L "$ZIG_LIB_DIR" \
    -lbyakaron \
    -sdk "$MACOS26_SDK" \
    -target "$TARGET" \
    -framework Cocoa \
    -framework InputMethodKit \
    -framework SwiftUI \
    -o "$IME_BUNDLE/Contents/MacOS/$IME_NAME"

echo ">>> Signing IME bundle (ad-hoc)..."
codesign --force --sign - \
    --entitlements "$RES_DIR/Byakaron.entitlements" \
    "$IME_BUNDLE"

# ---------------------------------------------------------------------------
# Step 3: Build the SwiftUI main app -> Byakaron.app
#   Sources: App/, Preferences/, Core/Dictionary, Core/Prediction,
#            Core/Settings, IME/Activation/IMEInstaller.
# ---------------------------------------------------------------------------
echo ">>> Building main app ($APP_NAME.app)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$RES_DIR/Info-app.plist" "$APP_BUNDLE/Contents/Info.plist"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# dictionary.json into Resources for SpellEngine.loadFromBundle()
cp "$PROJECT_ROOT/data/dictionary.json" "$APP_BUNDLE/Contents/Resources/dictionary.json"

# App icon
cp "$RES_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

GUI_SOURCES=(
    "$SRC_DIR/App/ByakaronApp.swift"
    "$SRC_DIR/App/Views/MainView.swift"
    "$SRC_DIR/App/Views/SettingsView.swift"
    "$SRC_DIR/App/Views/GuideView.swift"
    "$SRC_DIR/App/Views/LayoutView.swift"
    "$SRC_DIR/App/Views/BanglaSpellTextView.swift"
    "$SRC_DIR/App/KeyboardInstaller.swift"
    "$SRC_DIR/Core/Prediction/SpellChecker.swift"
    "$SRC_DIR/Core/Dictionary/SpellEngine.swift"
    "$SRC_DIR/Core/Transliteration/ZigTransliterator.swift"
    "$SRC_DIR/Core/Settings/ByakaronSettings.swift"
)

# The app links the Zig engine too so the shared transliteration wrapper is
# available app-side (e.g. for previews/spell views). It imports only the Zig
# header, not riti's, via a small dedicated bridging header.
swiftc "${GUI_SOURCES[@]}" \
    -O \
    -module-name "Byakaron_App" \
    -import-objc-header "$SRC_DIR/Core/Transliteration/ZigBridge.h" \
    -I "$ZIG_INCLUDE_DIR" \
    -L "$ZIG_LIB_DIR" \
    -lbyakaron \
    -sdk "$MACOS26_SDK" \
    -target "$TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ---------------------------------------------------------------------------
# Step 4: Embed the signed IME inside the main app
# ---------------------------------------------------------------------------
echo ">>> Embedding IME into main app..."
mkdir -p "$APP_BUNDLE/Contents/Library/InputMethods"
cp -R "$IME_BUNDLE" "$APP_BUNDLE/Contents/Library/InputMethods/$IME_NAME.app"

# ---------------------------------------------------------------------------
# Step 5: Sign the outer app LAST (inner already signed; no --deep so the
# inner IME signature is preserved).
# ---------------------------------------------------------------------------
echo ">>> Signing main app bundle (ad-hoc)..."
codesign --force --sign - \
    --entitlements "$RES_DIR/Byakaron.entitlements" \
    "$APP_BUNDLE"

echo ""
echo "=== Build complete ==="
echo "App bundle: $APP_BUNDLE"
echo "Embedded IME: $APP_BUNDLE/Contents/Library/InputMethods/$IME_NAME.app"
echo ""
echo "To install, run: ./scripts/install.sh"
