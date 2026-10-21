#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Install the system packages the Linux port needs.
#
#   sudo bash apps/linux/scripts/setup_deps.sh          # build + run
#   sudo bash apps/linux/scripts/setup_deps.sh --test   # + test toolchain (CI)
#
# `zig build linux` / `linux-app` compile against a pinned Ubuntu sysroot that
# the build downloads itself, so building needs no -dev packages. The default
# set is what running needs (IBus, the GTK3 IM module, glib-compile-schemas).
# `--test` adds a C compiler and the -dev packages the test helpers (smoke.sh,
# wayland_*.sh) build against with the system toolchain.
#
# Zig itself is not installed here: use 0.17.0 (pinned in .tool-versions).
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "error: run me with sudo — 'sudo bash $0'" >&2
    exit 1
fi

WITH_TEST=0
[[ "${1:-}" == "--test" ]] && WITH_TEST=1

PACKAGES=(
    ibus
    ibus-gtk3
    libglib2.0-bin
    gettext
)
if [[ $WITH_TEST -eq 1 ]]; then
    PACKAGES+=(
        build-essential
        pkg-config
        libibus-1.0-dev
        libglib2.0-dev
        libgtk-3-dev
    )
fi

echo ">>> apt-get update"
apt-get update -qq

echo ">>> installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}"

[[ $WITH_TEST -eq 1 ]] || { echo; echo "=== dependencies ready ==="; exit 0; }

# GTK4 is only needed for the IME typing tests (wayland_type.c), not the app.
if apt-cache show libgtk-4-dev >/dev/null 2>&1; then
    echo ">>> installing optional GTK4 (IME tests): libgtk-4-dev ibus-gtk4"
    apt-get install -y libgtk-4-dev ibus-gtk4 || true
fi

echo
echo ">>> verifying pkg-config modules"
STATUS=0
for m in ibus-1.0 glib-2.0 gtk+-3.0; do
    if v=$(pkg-config --modversion "$m" 2>/dev/null); then
        printf '    %-14s %s\n' "$m" "$v"
    else
        printf '    %-14s MISSING\n' "$m"
        STATUS=1
    fi
done

echo
if [[ $STATUS -eq 0 ]]; then
    echo "=== dependencies ready ==="
else
    echo "!!! some modules are still missing — see above" >&2
fi
exit $STATUS
