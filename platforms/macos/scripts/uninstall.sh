#!/bin/bash
set -euo pipefail

APP_NAME="Byakaron"
IME_BUNDLE_NAME="Byakaron Keyboard.app"
INPUT_METHODS_DIR="$HOME/Library/Input Methods"
APPLICATIONS_DIR="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
USER_DATA_DIR="$HOME/Library/Application Support/Byakaron"
PREFS_FILE="$HOME/Library/Preferences/dev.nuhu.labs.inputmethod.Byakaron.plist"
SHARED_PREFS_FILE="$HOME/Library/Preferences/dev.nuhu.labs.Byakaron.shared.plist"
APP_PREFS_FILE="$HOME/Library/Preferences/dev.nuhu.labs.Byakaron.plist"
SAVED_STATE_DIR="$HOME/Library/Saved Application State/dev.nuhu.labs.Byakaron.savedState"

echo "=== Uninstalling $APP_NAME ==="

# Kill running instances (main app + embedded IME helper, plus legacy names).
killall "$APP_NAME" 2>/dev/null || true
killall "Byakaron Keyboard" 2>/dev/null || true
killall "ByakaronIME" 2>/dev/null || true   # old name
killall "AvroBangla" 2>/dev/null || true    # legacy name
sleep 1

# Remove the installed IME helper.
for name in "$IME_BUNDLE_NAME" "ByakaronIME.app" "Byakaron.app" "AvroBangla.app"; do
    if [ -d "$INPUT_METHODS_DIR/$name" ]; then
        echo ">>> Removing $INPUT_METHODS_DIR/$name"
        rm -rf "$INPUT_METHODS_DIR/$name"
    fi
done

# Remove the main app.
for name in "$APP_NAME.app" "AvroBangla.app"; do
    if [ -d "$APPLICATIONS_DIR/$name" ] || [ -L "$APPLICATIONS_DIR/$name" ]; then
        echo ">>> Removing $APPLICATIONS_DIR/$name"
        rm -rf "$APPLICATIONS_DIR/$name"
    fi
done

# Drop every Byakaron registration from LaunchServices so a future install starts
# clean (no duplicate bundle-id paths from old build outputs, DerivedData, or the
# Trash competing to resolve the input source).
if [ -x "$LSREGISTER" ]; then
    echo ">>> Clearing LaunchServices registrations..."
    "$LSREGISTER" -dump 2>/dev/null \
        | grep -oE '/[^"]*Byakaron[^"]*\.app' \
        | sort -u \
        | while IFS= read -r p; do
            "$LSREGISTER" -u "$p" >/dev/null 2>&1 && echo "    unregistered: $p"
        done
fi

# Ask about user data.
if [ -d "$USER_DATA_DIR" ] || [ -f "$PREFS_FILE" ] || [ -f "$SHARED_PREFS_FILE" ] \
   || [ -f "$APP_PREFS_FILE" ] || [ -d "$SAVED_STATE_DIR" ]; then
    echo ""
    echo "User data found:"
    [ -d "$USER_DATA_DIR" ]    && echo "  - $USER_DATA_DIR (learned word selections)"
    [ -f "$SHARED_PREFS_FILE" ] && echo "  - $SHARED_PREFS_FILE (shared settings)"
    [ -f "$PREFS_FILE" ]       && echo "  - $PREFS_FILE (IME settings)"
    [ -f "$APP_PREFS_FILE" ]   && echo "  - $APP_PREFS_FILE (app settings)"
    [ -d "$SAVED_STATE_DIR" ]  && echo "  - $SAVED_STATE_DIR (window state)"
    echo ""
    read -p "Remove all user data? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$USER_DATA_DIR"    2>/dev/null || true
        rm -f  "$SHARED_PREFS_FILE" 2>/dev/null || true
        rm -f  "$PREFS_FILE"       2>/dev/null || true
        rm -f  "$APP_PREFS_FILE"   2>/dev/null || true
        rm -rf "$SAVED_STATE_DIR"  2>/dev/null || true
        echo ">>> User data removed."
    else
        echo ">>> User data preserved."
    fi
fi

echo ""
echo "=== Uninstall complete ==="
echo "Please log out and log back in to complete removal."
