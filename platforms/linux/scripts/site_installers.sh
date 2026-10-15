#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Write the website's installer files from scripts/web_install.sh:
#
#     bash platforms/linux/scripts/site_installers.sh <dir>
#
#   <dir>/install.sh        any CPU (detects it)       — the long-standing URL
#   <dir>/install-amd64.sh  Intel/AMD only              — the page's default command
#   <dir>/install-arm64.sh  ARM only                    — shown by the page's ARM button
#
# The per-CPU files stop with the right command if run on the other CPU.
# <dir> is app/public/byakaron in the nuhulabs.com repo.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/web_install.sh"
OUT="${1:?usage: site_installers.sh <dir>}"
mkdir -p "$OUT"

grep -q '^WANT_ARCH=""$' "$SRC" || { echo "error: no WANT_ARCH=\"\" line in $SRC" >&2; exit 1; }

cp "$SRC" "$OUT/install.sh"
for arch in amd64 arm64; do
    sed -e "s|^WANT_ARCH=\"\"$|WANT_ARCH=\"$arch\"|" \
        -e "s|byakaron/install.sh \| sudo bash|byakaron/install-$arch.sh \| sudo bash|" \
        "$SRC" > "$OUT/install-$arch.sh"
    grep -q "^WANT_ARCH=\"$arch\"$" "$OUT/install-$arch.sh"
done
chmod 644 "$OUT"/install*.sh
echo ">>> wrote install.sh, install-amd64.sh, install-arm64.sh to $OUT"
