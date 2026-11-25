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
# <system> is a dpkg architecture (the system has apt and dpkg), optionally
# with :<ID>:<ID_LIKE>[:cros] (cros: ChromeOS's Linux),
# pacman:<ID>:<ID_LIKE> (it has pacman, and that os-release ID / ID_LIKE),
# dnf:<ID>:<ID_LIKE> or zypper:<ID>:<ID_LIKE>[:tu] (rpm and that installer;
# tu: transactional-update too), ostree:<ID>:<ID_LIKE> (a read-only Fedora:
# rpm, rpm-ostree and a dnf that must not be used), none:<ID>:<ID_LIKE>, or ""
# (no package manager at all).
fake_system() {
    local dir="$1" sys="$2" machine="$3" system="$4" name="$5"
    local id="" like="" flag=""
    mkdir -p "$dir/bin"
    local tool
    for tool in bash sed head grep curl mktemp rm cat tail awk sha256sum cut tr env mkdir cp dirname touch; do
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
        dnf:*|zypper:*)
            local installer
            IFS=: read -r installer id like flag <<< "$system"
            # Not installed yet (-q prints "not installed" and fails).
            printf '#!/bin/bash\necho "package byakaron is not installed"; exit 1\n' > "$dir/bin/rpm"
            printf '#!/bin/bash\nexit 0\n' > "$dir/bin/$installer"
            chmod +x "$dir/bin/rpm" "$dir/bin/$installer"
            if [[ "$flag" == tu ]]; then
                printf '#!/bin/bash\nexit 0\n' > "$dir/bin/transactional-update"
                chmod +x "$dir/bin/transactional-update"
            fi
            ;;
        ostree:*)
            IFS=: read -r _ id like <<< "$system"
            touch "$dir/ostree-booted"
            # rpm -q: installed when $dir/installed holds a version; -qp: the
            # downloaded package's. rpm-ostree logs what it was asked.
            cat > "$dir/bin/rpm" <<EOF
#!/bin/bash
case "\$1" in
    -qp) echo 27.0.0~dev.3-1 ;;
    *) if [[ -s "$dir/installed" ]]; then cat "$dir/installed"; else echo "package byakaron is not installed"; exit 1; fi ;;
esac
EOF
            printf '#!/bin/bash\necho "$*" >> "%s/rpm-ostree.log"\n' "$dir" > "$dir/bin/rpm-ostree"
            printf '#!/bin/bash\necho "dnf must not run on a read-only system"; exit 1\n' > "$dir/bin/dnf"
            chmod +x "$dir/bin/rpm" "$dir/bin/rpm-ostree" "$dir/bin/dnf"
            ;;
        none:*)
            IFS=: read -r _ id like <<< "$system"
            ;;
        *)
            local dpkg_arch
            IFS=: read -r dpkg_arch id like flag <<< "$system"
            [[ "$flag" == cros ]] && touch "$dir/cros"
            printf '#!/bin/bash\n[[ "$1" == --print-architecture ]] && echo %s\n' "$dpkg_arch" > "$dir/bin/dpkg"
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
           BYAKARON_OSTREE_BOOTED="$dir/ostree-booted" BYAKARON_CROS_MARKER="$dir/cros" \
           BYAKARON_DEB_URL="file://$WORK/missing.deb" \
           BYAKARON_PKG_URL="file://$WORK/missing.pkg.tar.zst" \
           BYAKARON_RPM_URL="file://$WORK/missing.rpm" \
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
      "Detected: Arch Linux ARM, ARM 64-bit (aarch64)"
check "fedora"               install.sh       Linux  x86_64  dnf:fedora: "Fedora Linux 40 (Workstation Edition)" \
      "Detected: Fedora Linux 40 (Workstation Edition), Intel/AMD 64-bit (x86_64)"
check "fedora-arm"           install.sh       Linux  aarch64 dnf:fedora: "Fedora Linux 40 (Workstation Edition)" \
      "Detected: Fedora Linux 40 (Workstation Edition), ARM 64-bit (aarch64)"
check "rocky"                install.sh       Linux  x86_64  dnf:rocky:"rhel centos fedora" "Rocky Linux 9.4 (Blue Onyx)" \
      "Detected: Rocky Linux 9.4 (Blue Onyx), Intel/AMD 64-bit (x86_64)"
check "opensuse"             install.sh       Linux  x86_64  zypper:opensuse-tumbleweed:"opensuse suse" "openSUSE Tumbleweed" \
      "Detected: openSUSE Tumbleweed, Intel/AMD 64-bit (x86_64)"
check "rpm-reaches-download" install.sh       Linux  x86_64  dnf:fedora: "Fedora Linux 40 (Workstation Edition)" \
      "could not download file://$WORK/missing.rpm"
check "no-package-manager"   install.sh       Linux  x86_64  ""    "Gentoo Linux" \
      "Byakaron is packaged for Ubuntu, Debian, Arch Linux, Fedora, RHEL and openSUSE (apt, pacman, dnf or zypper). This is Gentoo Linux."
check "pacman-but-not-arch"  install.sh       Linux  x86_64  pacman:fedora: "Fedora Linux 40 (Workstation Edition)" \
      "This is Fedora Linux 40 (Workstation Edition)."
check "mac-reaches-download" install.sh       Darwin arm64   ""    "macOS" \
      "could not download file://$WORK/missing.dmg"

# Built on Debian or Ubuntu: apt, so the .deb.
check "kali"                 install.sh       Linux  x86_64  amd64:kali:debian "Kali GNU/Linux Rolling" \
      "Detected: Kali GNU/Linux Rolling, Intel/AMD 64-bit (amd64)"
check "kali-arm"             install.sh       Linux  aarch64 arm64:kali:debian "Kali GNU/Linux Rolling" \
      "Detected: Kali GNU/Linux Rolling, ARM 64-bit (arm64)"
check "linux-mint"           install.sh       Linux  x86_64  amd64:linuxmint:"ubuntu debian" "Linux Mint 22.2" \
      "Detected: Linux Mint 22.2, Intel/AMD 64-bit (amd64)"
check "lmde"                 install.sh       Linux  x86_64  amd64:linuxmint:debian "LMDE 7 (Gigi)" \
      "Detected: LMDE 7 (Gigi), Intel/AMD 64-bit (amd64)"
check "pop-os"               install.sh       Linux  x86_64  amd64:pop:"ubuntu debian" "Pop!_OS 24.04 LTS" \
      "Detected: Pop!_OS 24.04 LTS, Intel/AMD 64-bit (amd64)"
check "zorin"                install.sh       Linux  x86_64  amd64:zorin:"ubuntu debian" "Zorin OS 18" \
      "Detected: Zorin OS 18, Intel/AMD 64-bit (amd64)"
check "elementary"           install.sh       Linux  x86_64  amd64:elementary:ubuntu "elementary OS 8.1 Circe" \
      "Detected: elementary OS 8.1 Circe, Intel/AMD 64-bit (amd64)"
check "mx-linux"             install.sh       Linux  x86_64  amd64:debian: "MX 23.6 Libretto" \
      "Detected: MX 23.6 Libretto, Intel/AMD 64-bit (amd64)"
check "deepin"               install.sh       Linux  x86_64  amd64:deepin:debian "Deepin 25" \
      "Detected: Deepin 25, Intel/AMD 64-bit (amd64)"
check "chromeos"             install.sh       Linux  x86_64  amd64:debian::cros "Debian GNU/Linux 12 (bookworm)" \
      "Detected: ChromeOS's Linux (Debian GNU/Linux 12 (bookworm)), Intel/AMD 64-bit (amd64)"
check "chromeos-arm"         install.sh       Linux  aarch64 arm64:debian::cros "Debian GNU/Linux 12 (bookworm)" \
      "Detected: ChromeOS's Linux (Debian GNU/Linux 12 (bookworm)), ARM 64-bit (arm64)"
check "cachyos"              install.sh       Linux  x86_64  pacman:cachyos:arch "CachyOS Linux" \
      "Detected: CachyOS Linux, Intel/AMD 64-bit (x86_64)"
check "nobara"               install.sh       Linux  x86_64  dnf:nobara:fedora "Nobara Linux 42 (KDE Plasma)" \
      "Detected: Nobara Linux 42 (KDE Plasma), Intel/AMD 64-bit (x86_64)"
check "opensuse-leap"        install.sh       Linux  x86_64  zypper:opensuse-leap:"suse opensuse" "openSUSE Leap 16.0" \
      "Detected: openSUSE Leap 16.0, Intel/AMD 64-bit (x86_64)"

# Read-only systems: rpm-ostree on Fedora's, a reason everywhere else.
check "silverblue"           install.sh       Linux  x86_64  ostree:fedora: "Fedora Linux 43 (Silverblue)" \
      "Detected: Fedora Linux 43 (Silverblue) (read-only, rpm-ostree), Intel/AMD 64-bit (x86_64)"
check "bazzite"              install.sh       Linux  x86_64  ostree:bazzite:fedora "Bazzite" \
      "Detected: Bazzite (read-only, rpm-ostree), Intel/AMD 64-bit (x86_64)"
check "silverblue-download"  install.sh       Linux  x86_64  ostree:fedora: "Fedora Linux 43 (Silverblue)" \
      "could not download file://$WORK/missing.rpm"
check "steamos"              install.sh       Linux  x86_64  pacman:steamos:arch "SteamOS" \
      "SteamOS keeps its system read-only"
check "opensuse-aeon"        install.sh       Linux  x86_64  zypper:opensuse-aeon:"suse opensuse microos":tu "openSUSE Aeon" \
      "openSUSE Aeon keeps its system read-only (transactional-update)"
check "nixos"                install.sh       Linux  x86_64  none:nixos: "NixOS 25.05 (Warbler)" \
      "NixOS installs software from its configuration"
check "alpine"               install.sh       Linux  x86_64  none:alpine: "Alpine Linux v3.22" \
      "Alpine Linux v3.22 is built on musl"
check "void"                 install.sh       Linux  x86_64  none:void: "Void Linux" \
      "This is Void Linux."

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
           BYAKARON_OSTREE_BOOTED="$dir/ostree-booted" BYAKARON_CROS_MARKER="$dir/cros" \
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

# expect <label> <output or file text> <expected substring> [absent]
expect() {
    local label="$1" out="$2" want="$3" absent="${4:-}"
    local ok=0
    [[ "$out" == *"$want"* ]] && ok=1
    [[ -n "$absent" ]] && ok=$((1 - ok))
    if [[ $ok -eq 1 ]]; then
        printf '  ok   %-30s -> %s%s\n' "$label" "${absent:+no }" "$want"
    else
        printf '  FAIL %-30s -> %s\n       expected%s: %s\n' "$label" "$out" "${absent:+ no}" "$want"
        failures=$((failures + 1))
    fi
}

# A whole install, update and uninstall on ChromeOS's Linux and on Silverblue,
# with a fake sudo that runs the command, fake apt-get / dpkg-query /
# rpm-ostree that keep what is "installed" in $dir/installed, and a pinned
# package URL (no checksum step).
echo
echo "ChromeOS's Linux, whole install:"
dir="$WORK/flow-chromeos"
fake_system "$dir" Linux x86_64 amd64:debian::cros "Debian GNU/Linux 12 (bookworm)"
mkdir -p "$dir/home"
printf 'a .deb\n' > "$dir/byakaron.deb"
printf '#!/bin/bash\nexec "$@"\n' > "$dir/bin/sudo"
printf '#!/bin/bash\nif [[ "$*" == *purge* ]]; then rm -f "%s/installed"; else echo 1:27.0.0~dev.3 > "%s/installed"; fi\n' "$dir" "$dir" > "$dir/bin/apt-get"
printf '#!/bin/bash\n[[ "$*" == *byakaron-* ]] && exit 1\n[[ -s "%s/installed" ]] || exit 1\n[[ "$*" == *Version* ]] && cat "%s/installed"\nexit 0\n' "$dir" "$dir" > "$dir/bin/dpkg-query"
chmod +x "$dir/bin/sudo" "$dir/bin/apt-get" "$dir/bin/dpkg-query"
flow() {
    PATH="$dir/bin" HOME="$dir/home" BYAKARON_OS_RELEASE="$dir/os-release" \
        BYAKARON_OSTREE_BOOTED="$dir/ostree-booted" BYAKARON_CROS_MARKER="$dir/cros" \
        BYAKARON_SYSTEMD_USER_DIR="$dir/systemd-user" BYAKARON_DEB_URL="file://$dir/byakaron.deb" \
        BYAKARON_RPM_URL="file://$dir/byakaron.rpm" \
        "$dir/bin/bash" "$SRC" "$@" 2>&1 || true
}
dropin="$dir/systemd-user/cros-garcon.service.d/zz-byakaron-ibus.conf"
out="$(flow)"
expect "chromeos-installed"      "$out" "=== Byakaron 27.0.0-dev.3 is installed in ChromeOS's Linux. ==="
expect "chromeos-not-chrome"     "$out" "not in Chrome or Android apps"
expect "chromeos-garcon-dropin"  "$(cat "$dropin" 2>/dev/null)" 'Environment="GTK_IM_MODULE=ibus"'
expect "chromeos-sommelierrc"    "$(cat "$dir/home/.sommelierrc" 2>/dev/null)" "/usr/bin/ibus-daemon -drx"
out="$(flow)"
expect "chromeos-again"          "$out" "=== Byakaron 27.0.0-dev.3 is already the latest ==="
expect "chromeos-ibus-line-once" "$(grep -c ibus-daemon "$dir/home/.sommelierrc")" "1"
printf 'xrdb -merge ~/.Xresources\n' >> "$dir/home/.sommelierrc"
out="$(flow --uninstall)"
expect "chromeos-uninstalled"    "$out" "Linux apps use ChromeOS's keyboards again"
expect "chromeos-dropin-gone"    "$(ls "$dropin" 2>&1)" "No such file"
expect "chromeos-own-lines-kept" "$(cat "$dir/home/.sommelierrc")" "xrdb -merge ~/.Xresources"
expect "chromeos-ibus-line-gone" "$(cat "$dir/home/.sommelierrc")" "ibus-daemon" absent

echo
echo "Fedora Silverblue (rpm-ostree), whole install:"
dir="$WORK/flow-silverblue"
fake_system "$dir" Linux x86_64 ostree:fedora: "Fedora Linux 43 (Silverblue)"
printf 'an .rpm\n' > "$dir/byakaron.rpm"
printf '#!/bin/bash\nexec "$@"\n' > "$dir/bin/sudo"
chmod +x "$dir/bin/sudo"
out="$(flow)"
expect "silverblue-layered"      "$(cat "$dir/rpm-ostree.log")" "install --idempotent"
expect "silverblue-restart"      "$out" "=== Byakaron 27.0.0-dev.3 is added. Restart the computer, then add it as an input source: ==="
expect "silverblue-no-dnf"       "$out" "dnf must not run" absent
echo 27.0.0~dev.2-1 > "$dir/installed"
rm -f "$dir/rpm-ostree.log"
out="$(flow)"
expect "silverblue-swapped"      "$(cat "$dir/rpm-ostree.log")" "uninstall byakaron --install"
expect "silverblue-update"       "$out" "=== Byakaron 27.0.0-dev.2 is replaced by 27.0.0-dev.3 from the next start ==="
echo 27.0.0~dev.3-1 > "$dir/installed"
rm -f "$dir/rpm-ostree.log"
out="$(flow)"
expect "silverblue-latest"       "$out" "=== Byakaron 27.0.0-dev.3 is already the latest ==="
expect "silverblue-left-alone"   "$(cat "$dir/rpm-ostree.log" 2>/dev/null)" "install" absent
out="$(flow --uninstall)"
expect "silverblue-uninstall"    "$(cat "$dir/rpm-ostree.log")" "uninstall --idempotent byakaron"

echo
if [[ $failures -gt 0 ]]; then
    echo "WEB INSTALL TEST FAILED ($failures)"
    exit 1
fi
echo "web install test passed"
