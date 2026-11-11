#!/bin/bash
# Checks what the website installer decides on different computers, without
# installing anything: fake uname / dpkg / apt-get on a PATH of their own, a
# fake /etc/os-release, and a download URL that does not exist, so a supported
# system stops right after detection with "could not download".
#
#     bash apps/linux/tests/web_install_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)/web_install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The website serves one installer under three names (install.sh, plus the
# per-CPU names older links used); copy it the same way here.
mkdir -p "$WORK/site"
cp "$SRC" "$WORK/site/install.sh"
for name in install-amd64.sh install-arm64.sh; do
    cp "$SRC" "$WORK/site/$name"
done

failures=0

# fake_system <dir> <uname -s> <uname -m> <dpkg arch or ""> <PRETTY_NAME>
fake_system() {
    local dir="$1" sys="$2" machine="$3" arch="$4" name="$5"
    mkdir -p "$dir/bin"
    local tool
    for tool in bash sed head grep curl mktemp rm cat tail awk sha256sum cut; do
        ln -sf "$(command -v "$tool")" "$dir/bin/$tool"
    done
    printf '#!/bin/bash\ncase "$1" in -m) echo %s ;; *) echo %s ;; esac\n' "$machine" "$sys" > "$dir/bin/uname"
    if [[ -n "$arch" ]]; then
        printf '#!/bin/bash\n[[ "$1" == --print-architecture ]] && echo %s\n' "$arch" > "$dir/bin/dpkg"
        printf '#!/bin/bash\nexit 0\n' > "$dir/bin/apt-get"
        printf '#!/bin/bash\nexit 1\n' > "$dir/bin/dpkg-query"
    fi
    chmod +x "$dir/bin/uname"
    [[ -n "$arch" ]] && chmod +x "$dir/bin/dpkg" "$dir/bin/apt-get" "$dir/bin/dpkg-query"
    printf 'NAME="x"\nPRETTY_NAME="%s"\n' "$name" > "$dir/os-release"
}

# check <label> <script> <uname -s> <uname -m> <arch> <PRETTY_NAME> <expected substring>
check() {
    local label="$1" script="$2" expect="$7"
    local dir="$WORK/$label"
    fake_system "$dir" "$3" "$4" "$5" "$6"
    local out
    out="$(PATH="$dir/bin" BYAKARON_OS_RELEASE="$dir/os-release" \
           BYAKARON_DEB_URL="file://$WORK/missing.deb" \
           "$dir/bin/bash" "$WORK/site/$script" 2>&1 || true)"
    if [[ "$out" == *"$expect"* ]]; then
        printf '  ok   %-30s -> %s\n' "$label" "$(printf '%s' "$out" | grep -m1 -E 'Detected|error' )"
    else
        printf '  FAIL %-30s -> %s\n       expected: %s\n' "$label" "$out" "$expect"
        failures=$((failures + 1))
    fi
}

echo "website installer detection:"
check "ubuntu-amd64"         install.sh       Linux  x86_64  amd64 "Ubuntu 24.04.1 LTS" \
      "Detected: Ubuntu 24.04.1 LTS, Intel/AMD 64-bit (amd64)"
check "pi-os-64bit"          install.sh       Linux  aarch64 arm64 "Debian GNU/Linux 12 (bookworm)" \
      "Detected: Debian GNU/Linux 12 (bookworm), ARM 64-bit (arm64)"
check "ubuntu-26.04-amd64"   install.sh       Linux  x86_64  amd64 "Ubuntu 26.04.1 LTS" \
      "Detected: Ubuntu 26.04.1 LTS, Intel/AMD 64-bit (amd64)"
check "pi-os-trixie-64bit"   install.sh       Linux  aarch64 arm64 "Debian GNU/Linux 13 (trixie)" \
      "Detected: Debian GNU/Linux 13 (trixie), ARM 64-bit (arm64)"
check "old-arm-link-on-amd"  install-arm64.sh Linux  x86_64  amd64 "Ubuntu 22.04.4 LTS" \
      "Detected: Ubuntu 22.04.4 LTS, Intel/AMD 64-bit (amd64)"
check "old-amd-link-on-arm"  install-amd64.sh Linux  aarch64 arm64 "Ubuntu 24.04.1 LTS" \
      "Detected: Ubuntu 24.04.1 LTS, ARM 64-bit (arm64)"
check "supported-reaches-download" install.sh Linux  aarch64 arm64 "Ubuntu 22.04.4 LTS" \
      "could not download"
check "pi-os-32bit-on-64bit-pi" install.sh    Linux  aarch64 armhf "Raspbian GNU/Linux 12 (bookworm)" \
      "The processor is 64-bit, but the installed system is 32-bit"
check "pi-os-32bit"          install.sh       Linux  armv7l  armhf "Raspbian GNU/Linux 11 (bullseye)" \
      "this is a 32-bit ARM system (armhf"
check "32-bit-pc"            install.sh       Linux  i686    i386  "Ubuntu 18.04.6 LTS" \
      "32-bit PC system"
check "fedora-no-apt"        install.sh       Linux  x86_64  ""    "Fedora Linux 40 (Workstation Edition)" \
      "This is Fedora Linux 40 (Workstation Edition), which has no apt"
check "mac"                  install.sh       Darwin arm64   ""    "macOS" \
      "For a Mac: curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash"

# Where the .deb comes from, against a fake Byakaron-Assets on file:// URLs:
# latest/, or the newest prerelease while there is no latest, and the
# download checked against SHA256SUMS. apt-get is the fake that does nothing.
#
# download <label> <installer> <scenario: latest|preview|damaged|none> <expected substring>
download() {
    local label="$1" installer="$2" scenario="$3" expect="$4"
    local dir="$WORK/dl-$label" deb_name="byakaron_amd64.deb"
    fake_system "$dir" Linux x86_64 amd64 "Ubuntu 24.04.1 LTS"
    mkdir -p "$dir/latest" "$dir/pre"
    printf 'not really a deb\n' > "$dir/pre/$deb_name"
    (cd "$dir/pre" && sha256sum "$deb_name" > SHA256SUMS)
    printf '[{"tag_name": "v27.0.0-dev.1", "assets": [{"name": "%s", "browser_download_url": "file://%s/pre/%s"}]}]\n' \
        "$deb_name" "$dir" "$deb_name" > "$dir/releases.json"
    case "$scenario" in
        latest)  cp "$dir/pre/$deb_name" "$dir/pre/SHA256SUMS" "$dir/latest/" ;;
        damaged) printf '%064d  %s\n' 0 "$deb_name" > "$dir/pre/SHA256SUMS" ;;
        none)    printf '[]\n' > "$dir/releases.json" ;;
    esac
    local out
    out="$(PATH="$dir/bin" BYAKARON_OS_RELEASE="$dir/os-release" \
           BYAKARON_ASSETS_URL="file://$dir/latest" BYAKARON_API_URL="file://$dir/releases.json" \
           "$dir/bin/bash" "$installer" 2>&1 || true)"
    local ok=1
    [[ "$out" == *"$expect"* ]] || ok=0
    # Only the preview scenarios may say "preview".
    [[ "$scenario" == latest && "$out" == *preview* ]] && ok=0
    if [[ $ok -eq 1 ]]; then
        printf '  ok   %-30s -> %s\n' "$label" "$expect"
    else
        printf '  FAIL %-30s -> %s\n       expected: %s\n' "$label" "$out" "$expect"
        failures=$((failures + 1))
    fi
}

# The public command runs apps/web/app/public/install.sh (Linux + macOS);
# the per-CPU links run apps/linux/web_install.sh. Both share this logic.
PUBLIC="$(cd "$HERE/../../.." && pwd)/apps/web/app/public/install.sh"
echo
echo "where the .deb comes from:"
for installer in "$SRC" "$PUBLIC"; do
    [[ -f "$installer" ]] || { echo "  FAIL missing $installer"; failures=$((failures + 1)); continue; }
    tag="$(basename "$(dirname "$installer")")"
    download "$tag-latest"  "$installer" latest  "checksum OK"
    download "$tag-preview" "$installer" preview "no stable release yet: installing the newest preview build"
    download "$tag-preview-sum" "$installer" preview "checksum OK"
    download "$tag-damaged" "$installer" damaged "does not match SHA256SUMS"
    download "$tag-none"    "$installer" none    "no release has it yet"
done

echo
if [[ $failures -gt 0 ]]; then
    echo "WEB INSTALL TEST FAILED ($failures)"
    exit 1
fi
echo "web install test passed"
