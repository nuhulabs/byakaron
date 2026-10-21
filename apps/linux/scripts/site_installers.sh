#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Write the website's installer files from scripts/web_install.sh:
#
#     bash apps/linux/scripts/site_installers.sh <dir>
#
#   <dir>/install.sh        the one command the page shows; detects the CPU
#   <dir>/install-amd64.sh  \  the same installer under the names the page used
#   <dir>/install-arm64.sh  /  while it had one command per CPU, so links shared
#                              then keep working on any computer
#
# <dir> is app/public/byakaron in the nuhulabs.com repo.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/web_install.sh"
OUT="${1:?usage: site_installers.sh <dir>}"
mkdir -p "$OUT"

cp "$SRC" "$OUT/install.sh"
for name in install-amd64.sh install-arm64.sh; do
    {
        head -n 1 "$SRC"
        echo "# $name is kept for links shared earlier; it is the same installer as"
        echo "# install.sh and works on Intel/AMD and ARM alike."
        tail -n +2 "$SRC"
    } > "$OUT/$name"
done
chmod 644 "$OUT"/install*.sh
echo ">>> wrote install.sh (+ install-amd64.sh, install-arm64.sh, same installer) to $OUT"
