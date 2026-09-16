#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Bundle the GTK companion app as a Flatpak. The IBus engine is NOT in here:
# ibus-daemon only scans /usr/share/ibus/component, which a sandbox cannot
# register. The .deb remains the IME artefact; this is the app for people who
# want Spelling / Layout / Setup from Flathub-style packaging.
#
#     bash platforms/linux/scripts/package_flatpak.sh
#
# Uses org.gnome.Platform as both runtime and SDK so a box that already has
# the Platform — and not org.gnome.Sdk — can still pack the binary we already
# built. spell.db is omitted (364 MB; the app runs without it).
#
# Produces: platforms/linux/build/dev.nuhu.labs.Byakaron.flatpak
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"

APP_ID="dev.nuhu.labs.Byakaron"
RUNTIME="org.gnome.Platform"
BRANCH="${FLATPAK_BRANCH:-49}"
BUILD_DIR="$PROJECT_ROOT/build/flatpak"
APPDIR="$BUILD_DIR/appdir"
REPO="$BUILD_DIR/repo"
OUT="$PROJECT_ROOT/build/${APP_ID}.flatpak"

if ! command -v flatpak >/dev/null; then
    echo "error: flatpak is not installed" >&2
    exit 1
fi
if ! command -v rsvg-convert >/dev/null; then
    echo "error: rsvg-convert is not installed (apt install librsvg2-bin)" >&2
    exit 1
fi

if ! flatpak info "runtime/${RUNTIME}/$(uname -m)/${BRANCH}" >/dev/null 2>&1; then
    echo "error: ${RUNTIME}//${BRANCH} is not installed" >&2
    echo "       flatpak install flathub ${RUNTIME}//${BRANCH}" >&2
    exit 1
fi

# Always rebuild against glibc 2.31. Skipping when zig-out/bin already exists
# is how a 24.04-only binary got shipped before.
# shellcheck source=compat.sh
source "$SCRIPT_DIR/compat.sh"
COMPAT_TARGET="$(byk_compat_target_flag)"
if [[ -z "$COMPAT_TARGET" ]]; then
    echo "error: no glibc 2.31 Zig target for $(uname -m)" >&2
    exit 1
fi

echo ">>> Building the GTK3 app (ReleaseFast, $COMPAT_TARGET)..."
( cd "$REPO_ROOT" && \
  PATH="$HOME/.local/bin:/usr/local/bin:$PATH" \
  zig build linux-app -Doptimize=ReleaseFast $COMPAT_TARGET )
SRC_APP="$REPO_ROOT/zig-out/bin/byakaron"
[[ -x "$SRC_APP" ]] || { echo "error: $SRC_APP missing" >&2; exit 1; }
byk_assert_glibc_20_04 "$SRC_APP"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$PROJECT_ROOT/build"

echo ">>> flatpak build-init (runtime=SDK=${RUNTIME}//${BRANCH})..."
# The SDK slot is the Platform on purpose: we copy a prebuilt binary and do
# not compile inside the sandbox, so org.gnome.Sdk is not required.
flatpak build-init "$APPDIR" "$APP_ID" "$RUNTIME" "$RUNTIME" "$BRANCH"

echo ">>> installing binary, desktop file, icon..."
flatpak build "$APPDIR" install -D -m 755 "$SRC_APP" /app/bin/byakaron
flatpak build "$APPDIR" install -d /app/share/applications

DESKTOP="$BUILD_DIR/${APP_ID}.desktop"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Byakaron
GenericName=Bangla Input & Spell Checker
Comment=Type Bangla phonetically and check spelling
Exec=byakaron
Icon=${APP_ID}
Terminal=false
Categories=Utility;TextTools;
Keywords=Bangla;Bengali;spell;spelling;input;phonetic;avro;keyboard;
StartupNotify=true
StartupWMClass=${APP_ID}
EOF
flatpak build "$APPDIR" install -D -m 644 "$DESKTOP" \
    "/app/share/applications/${APP_ID}.desktop"
flatpak build "$APPDIR" install -d /app/share/metainfo
flatpak build "$APPDIR" install -D -m 644 "$PROJECT_ROOT/Resources/${APP_ID}.metainfo.xml" "/app/share/metainfo/${APP_ID}.metainfo.xml"

# Flatpak's export validator often rejects this SVG (gdk-pixbuf in the
# export environment has no SVG loader). A PNG is what GNOME Software shows.
ICON_PNG="$BUILD_DIR/${APP_ID}.png"
rsvg-convert -w 128 -h 128 "$PROJECT_ROOT/Resources/byakaron.svg" -o "$ICON_PNG"
flatpak build "$APPDIR" install -d /app/share/icons/hicolor/128x128/apps
flatpak build "$APPDIR" install -D -m 644 "$ICON_PNG" \
    "/app/share/icons/hicolor/128x128/apps/${APP_ID}.png"

echo ">>> installing GSettings schema..."
SCHEMA_STAGE="$BUILD_DIR/schemas"
mkdir -p "$SCHEMA_STAGE"
cp "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.gschema.xml" "$SCHEMA_STAGE/"
glib-compile-schemas "$SCHEMA_STAGE"
flatpak build "$APPDIR" install -d /app/share/glib-2.0/schemas
flatpak build "$APPDIR" install -D -m 644 \
    "$SCHEMA_STAGE/dev.nuhu.labs.Byakaron.gschema.xml" \
    /app/share/glib-2.0/schemas/dev.nuhu.labs.Byakaron.gschema.xml
flatpak build "$APPDIR" install -D -m 644 \
    "$SCHEMA_STAGE/gschemas.compiled" \
    /app/share/glib-2.0/schemas/gschemas.compiled

echo ">>> build-finish..."
flatpak build-finish "$APPDIR" \
    --command=byakaron \
    --share=ipc \
    --socket=wayland \
    --socket=fallback-x11 \
    --device=dri \
    --talk-name=ca.desrt.dconf \
    --filesystem=xdg-run/dconf \
    --talk-name=org.freedesktop.portal.Desktop

echo ">>> exporting bundle..."
rm -rf "$REPO"
flatpak build-export "$REPO" "$APPDIR" "$BRANCH"
rm -f "$OUT"
flatpak build-bundle "$REPO" "$OUT" "$APP_ID" "$BRANCH"

echo
echo "=== Built: $OUT ==="
echo "    size: $(du -h "$OUT" | cut -f1)"
echo
echo "This is the companion app only. The IBus engine still needs the .deb"
echo "(or sudo bash platforms/linux/scripts/install.sh)."
echo
echo "Install the bundle with:"
echo "    flatpak install --user $OUT"
