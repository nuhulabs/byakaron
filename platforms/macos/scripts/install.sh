#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Byakaron"
APP_BUNDLE="$PROJECT_ROOT/build/$APP_NAME.app"
APPLICATIONS_DIR="/Applications"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run ./scripts/build.sh first."
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

# Install the main app to /Applications. The app is sandboxed, so it no longer
# installs the keyboard itself: from the Setup guide the user clicks "Reveal
# Keyboard" and drags the embedded "Byakaron Keyboard.app" into
# ~/Library/Input Methods (see KeyboardInstaller).
echo ">>> Copying $APP_NAME.app to $APPLICATIONS_DIR/..."
cp -R "$APP_BUNDLE" "$APPLICATIONS_DIR/"

# Clear extended attributes so Gatekeeper doesn't block the ad-hoc-signed build.
xattr -cr "$APPLICATIONS_DIR/$APP_NAME.app" 2>/dev/null || true

# Launch the app so the user can run the keyboard setup from the Help → Setup guide.
echo ">>> Launching $APP_NAME..."
open "$APPLICATIONS_DIR/$APP_NAME.app"

echo ""
echo "=== Installation complete ==="
echo ""
echo "To enable the keyboard:"
echo "  1. In Byakaron, open Help → Byakaron Setup Guide (⌘?)"
echo "  2. Click 'Reveal Keyboard' to show 'Byakaron Keyboard.app' in Finder"
echo "  3. Drag it into ~/Library/Input Methods ('Open Folder' opens it for you)"
echo "  4. Go to System Settings → Keyboard → Input Sources"
echo "  5. Click '+' → search for 'Byakaron' → select Byakaron → Add"
echo "  6. Use Ctrl+Space (or the Globe key) to switch input methods"
