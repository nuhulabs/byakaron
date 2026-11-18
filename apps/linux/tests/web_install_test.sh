#!/bin/bash
# Checks what the website installer (apps/web/app/public/install.sh, served
# as https://byakaron.com/install.sh) decides on different computers, without
# installing anything: fake uname / dpkg / apt-get / pacman on a PATH of their
# own, a fake /etc/os-release, and a download URL that does not exist, so a
# supported system stops right after detection with "could not download".
#
#     bash apps/linux/tests/web_install_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)/apps/web/app/public/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[[ -f "$SRC" ]] || { echo "missing $SRC"; exit 1; }

failures=0

# fake_system <dir> <uname -s> <uname -m> <system> <PRETTY_NAME>
# <system> is a dpkg architecture (the system has apt and dpkg),
# pacman:<ID>:<ID_LIKE> (it has pacman, and that os-release ID / ID_LIKE),
# or "" (neither).
fake_system() {
    local dir="$1" sys="$2" machine="$3" system="$4" name="$5"
    local id="" like=""
    mkdir -p "$dir/bin"
    local tool
    for tool in bash sed head grep curl mktemp rm cat tail awk sha256sum cut; do
        ln -sf "$(command -v "$tool")" "$dir/bin/$tool"
    done
    printf '#!/bin/bash\ncase "$1" in -m) echo %s ;; *) echo %s ;; esac\n' "$machine" "$sys" > "$dir/bin/uname"
    chmod +x "$dir/bin/uname"
    case "$system" in
        "") ;;
        pacman:*)
            IFS=: read -r _ id like <<< "$system"
            # Not installed yet (-Q fails); -U "installs".
            printf '#!/bin/bash\ncase "$1" in -Q) exit 1 ;; *) exit 0 ;; esac\n' > "$dir/bin/pacman"
            chmod +x "$dir/bin/pacman"
            ;;
        *)
            printf '#!/bin/bash\n[[ "$1" == --print-architecture ]] && echo %s\n' "$system" > "$dir/bin/dpkg"
            printf '#!/bin/bash\nexit 0\n' > "$dir/bin/apt-get"
            printf '#!/bin/bash\nexit 1\n' > "$dir/bin/dpkg-query"
            chmod +x "$dir/bin/dpkg" "$dir/bin/apt-get" "$dir/bin/dpkg-query"
            ;;
    esac
    printf 'NAME="x"\nPRETTY_NAME="%s"\nID=%s\nID_LIKE="%s"\n' "$name" "$id" "$like" > "$dir/os-release"
}

# check <label> <script> <uname -s> <uname -m> <system> <PRETTY_NAME> <expected substring>
check() {
    local label="$1" script="$2" expect="$7"
    local dir="$WORK/$label"
    fake_system "$dir" "$3" "$4" "$5" "$6"
    local out
    out="$(PATH="$dir/bin" BYAKARON_OS_RELEASE="$dir/os-release" \
           BYAKARON_DEB_URL="file://$WORK/missing.deb" \
           BYAKARON_PKG_URL="file://$WORK/missing.pkg.tar.zst" \
           BYAKARON_DMG_URL="file://$WORK/missing.dmg" \
           "$dir/bin/bash" "$SRC" 2>&1 || true)"
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
check "supported-reaches-download" install.sh Linux  aarch64 arm64 "Ubuntu 22.04.4 LTS" \
      "could not download"
check "pi-os-32bit-on-64bit-pi" install.sh    Linux  aarch64 armhf "Raspbian GNU/Linux 12 (bookworm)" \
      "The processor is 64-bit, but the installed system is 32-bit"
check "pi-os-32bit"          install.sh       Linux  armv7l  armhf "Raspbian GNU/Linux 11 (bullseye)" \
      "this is a 32-bit ARM system (armhf"
check "32-bit-pc"            install.sh       Linux  i686    i386  "Ubuntu 18.04.6 LTS" \
      "32-bit PC system"
check "arch"                 install.sh       Linux  x86_64  pacman:arch: "Arch Linux" \
      "Detected: Arch Linux, Intel/AMD 64-bit (x86_64)"
check "manjaro"              install.sh       Linux  x86_64  pacman:manjaro:arch "Manjaro Linux" \
      "Detected: Manjaro Linux, Intel/AMD 64-bit (x86_64)"
check "endeavouros"          install.sh       Linux  x86_64  pacman:endeavouros:arch "EndeavourOS" \
      "Detected: EndeavourOS, Intel/AMD 64-bit (x86_64)"
check "arch-reaches-download" install.sh      Linux  x86_64  pacman:arch: "Arch Linux" \
      "could not download"
check "arch-linux-arm"       install.sh       Linux  aarch64 pacman:archarm:arch "Arch Linux ARM" \
      "this is Arch Linux ARM (Arch Linux ARM). Byakaron's Arch package is for Intel/AMD 64-bit"
check "fedora"               install.sh       Linux  x86_64  ""    "Fedora Linux 40 (Workstation Edition)" \
      "Byakaron is packaged for Ubuntu, Debian and Arch Linux (apt or pacman). This is Fedora Linux 40 (Workstation Edition)."
check "pacman-but-not-arch"  install.sh       Linux  x86_64  pacman:fedora: "Fedora Linux 40 (Workstation Edition)" \
      "This is Fedora Linux 40 (Workstation Edition)."
check "mac-reaches-download" install.sh       Darwin arm64   ""    "macOS" \
      "could not download file://$WORK/missing.dmg"

# Where the package comes from, against a fake Byakaron-Assets on file:// URLs:
# latest/, or the newest prerelease while there is no latest, and the
# download checked against SHA256SUMS. apt-get and pacman are fakes that do
# nothing.
#
# download <label> <installer> <scenario: latest|preview|damaged|none> <expected substring> <deb|arch>
download() {
    local label="$1" installer="$2" scenario="$3" expect="$4" kind="$5"
    local dir="$WORK/dl-$label" name
    if [[ "$kind" == arch ]]; then
        name="byakaron_x86_64.pkg.tar.zst"
        fake_system "$dir" Linux x86_64 pacman:arch: "Arch Linux"
    else
        name="byakaron_amd64.deb"
        fake_system "$dir" Linux x86_64 amd64 "Ubuntu 24.04.1 LTS"
    fi
    mkdir -p "$dir/latest" "$dir/pre"
    printf 'not really a package\n' > "$dir/pre/$name"
    (cd "$dir/pre" && sha256sum "$name" > SHA256SUMS)
    printf '[{"tag_name": "v27.0.0-dev.1", "assets": [{"name": "%s", "browser_download_url": "file://%s/pre/%s"}]}]\n' \
        "$name" "$dir" "$name" > "$dir/releases.json"
    case "$scenario" in
        latest)  cp "$dir/pre/$name" "$dir/pre/SHA256SUMS" "$dir/latest/" ;;
        damaged) printf '%064d  %s\n' 0 "$name" > "$dir/pre/SHA256SUMS" ;;
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

echo
echo "where the package comes from:"
for kind in deb arch; do
    download "$kind-latest"      "$SRC" latest  "checksum OK" "$kind"
    download "$kind-preview"     "$SRC" preview "no stable release yet: installing the newest preview build" "$kind"
    download "$kind-preview-sum" "$SRC" preview "checksum OK" "$kind"
    download "$kind-damaged"     "$SRC" damaged "does not match SHA256SUMS" "$kind"
    download "$kind-none"        "$SRC" none    "no release has it yet" "$kind"
done

echo
if [[ $failures -gt 0 ]]; then
    echo "WEB INSTALL TEST FAILED ($failures)"
    exit 1
fi
echo "web install test passed"
