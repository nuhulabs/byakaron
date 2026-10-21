#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Install Byakaron the way a user does — the website installer, which detects
# the CPU and downloads the latest release — in clean containers, then check
# the result with test_installed.sh (files, icon, app window, typing through
# the installed engine).
#
#     bash apps/linux/scripts/test_install_matrix.sh <ime-test binary> [image ...]
#
# Default images: ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 debian:bookworm
# (bookworm is what Raspberry Pi OS 64-bit is built on). Run it on an arm64
# host (CI: ubuntu-24.04-arm) to test the ARM package. The IME test binary
# must be built for glibc 2.31 (zig build linux-test with compat.sh's target).
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IME_TEST="${1:?usage: test_install_matrix.sh <ime-test binary> [image ...]}"
shift
IMAGES=("$@")
[[ ${#IMAGES[@]} -gt 0 ]] || IMAGES=(ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 debian:bookworm)
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
[[ -x "$IME_TEST" ]] || { echo "error: $IME_TEST is not an executable" >&2; exit 1; }

# Under build/, not /tmp: snap-packaged Docker cannot mount /tmp.
mkdir -p "$SCRIPT_DIR/../build"
WORK="$(mktemp -d "$SCRIPT_DIR/../build/install-matrix.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$IME_TEST" "$WORK/ime-test"
cat > "$WORK/inside.sh" <<'IN'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
apt-get update -qq >/dev/null
apt-get install -y -qq curl ca-certificates xvfb dbus-x11 x11-utils \
    python3-gi gir1.2-gdkpixbuf-2.0 librsvg2-common >/dev/null 2>&1 \
    || { echo "  FAIL could not install the test tools"; exit 1; }
bash /s/web_install.sh > /tmp/install.log 2>&1 || { echo "  FAIL installer:"; tail -15 /tmp/install.log; exit 1; }
grep -E '^>>> (Detected|downloading)' /tmp/install.log | sed 's/^/  /'
bash /s/test_installed.sh /w/ime-test
IN

failed=()
for image in "${IMAGES[@]}"; do
    echo "=== $image ($(uname -m))"
    log="$WORK/$(echo "$image" | tr ':/' '__').log"
    if docker run --rm -v "$WORK:/w:ro" -v "$SCRIPT_DIR:/s:ro" "$image" bash /w/inside.sh > "$log" 2>&1; then
        grep -E '^  >>>|app version|icon loads|app window|ime test passed|installed check' "$log"
    else
        grep -E '^  >>>|FAIL|expected|error' "$log" | head -15
        failed+=("$image")
    fi
done

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "INSTALL MATRIX FAILED: ${failed[*]}"
    exit 1
fi
echo "install matrix passed: ${IMAGES[*]}"
