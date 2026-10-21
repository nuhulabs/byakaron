#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Byakaron"
APP_BUNDLE="$PROJECT_ROOT/build/$APP_NAME.app"
APPLICATIONS_DIR="/Applications"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Drop stale LaunchServices registrations for every Byakaron bundle EXCEPT the one
# we just installed in /Applications. macOS resolves a bundle id to a single
# canonical path, so leftover copies (old build/ outputs, Xcode DerivedData, the
# Trash, previous installs) can make it resolve the input source to the wrong path
# — and then the keyboard never appears in System Settings → Input Sources.
prune_stale_registrations() {
    [ -x "$LSREGISTER" ] || return 0
    local keep="$APPLICATIONS_DIR/$APP_NAME.app"
    "$LSREGISTER" -dump 2>/dev/null \
        | grep -oE '/[^"]*Byakaron[^"]*\.app' \
        | sort -u \
        | while IFS= read -r p; do
            case "$p" in
                "$keep" | "$keep"/*) continue ;;  # keep the freshly installed app + its embed
            esac
            "$LSREGISTER" -u "$p" >/dev/null 2>&1 && echo ">>> Unregistered stale copy: $p"
        done
}

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run zig build macos first."
    exit 1
fi

echo "=== Installing $APP_NAME ==="

# Kill any running instances (main app + embedded IME helper, plus old names).
killall "$APP_NAME" 2>/dev/null || true
killall "Byakaron Keyboard" 2>/dev/null || true
killall "ByakaronIME" 2>/dev/null || true   # old name
killall "AvroBangla" 2>/dev/null || true    # legacy name
sleep 1

# Remove old installations (including legacy names and the old Input Methods copy).
rm -rf "$APPLICATIONS_DIR/$APP_NAME.app" 2>/dev/null || true
rm -rf "$APPLICATIONS_DIR/AvroBangla.app" 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/$APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/ByakaronIME.app" 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/Byakaron Keyboard.app" 2>/dev/null || true

# Install the main app to /Applications. On first launch the (non-sandboxed) app
# copies its embedded "Byakaron Keyboard.app" into ~/Library/Input Methods and
# registers it (see KeyboardInstaller.ensureInstalled). A sandboxed build instead
# offers a manual "Reveal Keyboard" button in the in-app Setup guide.
echo ">>> Copying $APP_NAME.app to $APPLICATIONS_DIR/..."
cp -R "$APP_BUNDLE" "$APPLICATIONS_DIR/"

# Clear extended attributes so Gatekeeper doesn't block the ad-hoc-signed build.
xattr -cr "$APPLICATIONS_DIR/$APP_NAME.app" 2>/dev/null || true

# Register the just-installed app (and its embedded keyboard) with LaunchServices,
# then prune any other Byakaron copies so the bundle ids resolve to /Applications.
echo ">>> Cleaning up stale LaunchServices registrations..."
"$LSREGISTER" -f "$APPLICATIONS_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
prune_stale_registrations

# Launch the app so it installs + registers the keyboard, then opens the Setup tab
# automatically if the input source still needs to be added.
echo ">>> Launching $APP_NAME..."
open "$APPLICATIONS_DIR/$APP_NAME.app"

echo ""
echo "=== Installation complete ==="
echo ""
echo "To enable the keyboard:"
echo "  1. In Byakaron, open Settings (⌘,) → Setup"
echo "  2. Go to System Settings → Keyboard → Input Sources"
echo "  3. Click '+' → search for 'Byakaron' → select Byakaron → Add"
echo "  4. Use Ctrl+Space (or the Globe key) to switch input methods"
echo ""
echo "If Byakaron isn't listed, use 'Reveal Keyboard' in Settings → Setup to"
echo "install it manually."
