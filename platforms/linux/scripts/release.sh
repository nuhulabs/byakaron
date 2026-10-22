#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Release Byakaron for Linux in one go, or one stage at a time:
#
#   release.sh prepare <version> "<one-line summary>"
#       Bump the version everywhere it is written (app.h, IBus component,
#       package_deb.sh, the installer's fallback, README/ARM, linux-deb.yml),
#       add an AppStream <release> with the summary, commit and tag
#       linux-<version>. Nothing is pushed.
#
#   release.sh verify <version>
#       Build the amd64 .deb and install it in clean Docker ubuntu:20.04,
#       22.04 and 24.04 through the website installer; check files, icon,
#       version and typing through the installed engine (test_installed.sh).
#
#   release.sh publish <version> <notes.md>
#       Push the branch and tag, wait for the tag's CI run (it builds, installs
#       and types through both .debs, amd64 and arm64), download both, check
#       their package/version/arch, and create the release on
#       nuhulabs/Byakaron-Assets marked Latest.
#
#   release.sh website <version> [path to the nuhulabs.com checkout]
#       Regenerate the site's install.sh / install-amd64.sh / install-arm64.sh
#       from web_install.sh in a worktree of origin/main, push, wait for the
#       deploy, and check the live files and the page.
#
#   release.sh all <version> "<summary>" <notes.md> [site checkout]
#
# Needs gh (logged in), git, docker for `verify`. Commits carry no co-author
# trailer. Each stage checks its own result and stops on the first failure.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd)"
SRC_REPO="${BYAKARON_SRC_REPO:-nuhulabs/byakaron}"
ASSETS_REPO="${BYAKARON_ASSETS_REPO:-nuhulabs/Byakaron-Assets}"
SITE_REPO="${BYAKARON_SITE_REPO:-nuhulabs/nuhulabs.com}"
BUILD="$PROJECT_ROOT/build"

say() { echo ">>> $*"; }
die() { echo "error: $*" >&2; exit 1; }

check_version() {
    [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got '${1:-}'"
}

current_version() {
    sed -n 's/^#define BYK_APP_VERSION "\(.*\)"$/\1/p' "$PROJECT_ROOT/App/app.h"
}

# Replace exactly one occurrence, or fail loudly: a silent miss would ship a
# package that says the old version (it happened to 0.1.7 once).
bump() { # bump <file> <old> <new>
    local file="$1" old="$2" new="$3"
    local n
    n=$(grep -cF -- "$old" "$file" || true)
    [[ "$n" -ge 1 ]] || die "$file: '$old' not found"
    OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# ── prepare ────────────────────────────────────────────────────────────────

stage_prepare() {
    local version="$1" summary="$2"
    check_version "$version"
    [[ -n "$summary" ]] || die "give a one-line summary for the AppStream release notes"
    local old
    old="$(current_version)"
    [[ "$old" != "$version" ]] || die "already at $version"
    git -C "$REPO_ROOT" diff --quiet && git -C "$REPO_ROOT" diff --cached --quiet \
        || die "working tree has changes; commit or stash them first"
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/linux-$version" >/dev/null \
        && die "tag linux-$version already exists"

    say "bumping $old -> $version"
    bump "$PROJECT_ROOT/App/app.h" "#define BYK_APP_VERSION \"$old\"" "#define BYK_APP_VERSION \"$version\""
    bump "$PROJECT_ROOT/Resources/byakaron.xml.in" "<version>$old</version>" "<version>$version</version>"
    bump "$PROJECT_ROOT/scripts/package_deb.sh" "VERSION=\"\${VERSION:-$old}\"" "VERSION=\"\${VERSION:-$version}\""
    bump "$PROJECT_ROOT/scripts/web_install.sh" "VERSION_FALLBACK=\"$old\"" "VERSION_FALLBACK=\"$version\""
    bump "$PROJECT_ROOT/README.md" "byakaron_${old}_amd64.deb" "byakaron_${version}_amd64.deb"
    bump "$PROJECT_ROOT/ARM.md" "byakaron_${old}_arm64.deb" "byakaron_${version}_arm64.deb"
    bump "$REPO_ROOT/.github/workflows/linux-deb.yml" "linux-$old platforms" "linux-$version platforms"
    bump "$REPO_ROOT/.github/workflows/linux-deb.yml" "\"Linux $old\"" "\"Linux $version\""

    local today escaped
    today="$(date +%Y-%m-%d)"
    escaped="$(printf '%s' "$summary" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
    VERSION="$version" TODAY="$today" SUMMARY="$escaped" perl -0pi -e \
        's|<releases>\n|<releases>\n    <release version="$ENV{VERSION}" date="$ENV{TODAY}">\n      <description>\n        <p>$ENV{SUMMARY}</p>\n      </description>\n    </release>\n|' \
        "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml"
    grep -q "<release version=\"$version\"" "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml" \
        || die "AppStream release entry not added"
    if command -v appstreamcli >/dev/null; then
        appstreamcli validate --no-net "$PROJECT_ROOT/Resources/dev.nuhu.labs.Byakaron.metainfo.xml" >/dev/null \
            || die "AppStream metainfo no longer validates"
    fi

    local left
    left="$(git -C "$REPO_ROOT" grep -n -F "$old" -- platforms/linux .github \
            | grep -v -E 'DAILY_PLAN|metainfo.xml|release version' || true)"
    [[ -z "$left" ]] || { echo "$left" >&2; die "old version still written somewhere above"; }

    git -C "$REPO_ROOT" add -A platforms/linux .github
    git -C "$REPO_ROOT" commit -q -m "release(linux): $version" -m "$summary"
    git -C "$REPO_ROOT" tag -a "linux-$version" -m "Byakaron for Linux $version"
    say "committed and tagged linux-$version (not pushed)"
}

# ── verify ─────────────────────────────────────────────────────────────────

stage_verify() {
    local version="$1"
    check_version "$version"
    command -v docker >/dev/null || die "verify needs docker"
    [[ "$(current_version)" == "$version" ]] || die "app.h says $(current_version), not $version (run prepare)"

    say "building the amd64 .deb"
    bash "$SCRIPT_DIR/package_deb.sh" > "$BUILD/release-package.log" 2>&1 \
        || { tail -20 "$BUILD/release-package.log"; die "package_deb.sh failed"; }
    local deb="$BUILD/byakaron_${version}_amd64.deb"
    [[ -f "$deb" ]] || die "$deb was not built"

    # The IME test binary for the containers: glibc 2.31 like the package.
    # shellcheck source=compat.sh
    source "$SCRIPT_DIR/compat.sh"
    ( cd "$REPO_ROOT" && zig build linux-test -Doptimize=ReleaseFast $(byk_compat_target_flag) )
    cp "$REPO_ROOT/zig-out/bin/byakaron-ime-test" "$BUILD/ime-test-2.31"

    local inside="$BUILD/release-verify-inside.sh"
    cat > "$inside" <<'IN'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl ca-certificates xvfb dbus-x11 python3-gi gir1.2-gdkpixbuf-2.0 librsvg2-common >/dev/null 2>&1
BYAKARON_DEB_URL="file:///w/$1" bash /s/web_install.sh > /tmp/install.log 2>&1 || { tail -15 /tmp/install.log; exit 1; }
bash /s/test_installed.sh /w/ime-test-2.31 "$2"
IN
    local failed=0 v
    for v in 20.04 22.04 24.04; do
        say "clean ubuntu:$v"
        if docker run --rm -v "$BUILD:/w" -v "$SCRIPT_DIR:/s:ro" "ubuntu:$v" \
                bash /w/release-verify-inside.sh "byakaron_${version}_amd64.deb" "$version" \
                > "$BUILD/release-verify-$v.log" 2>&1; then
            echo "    ok   ubuntu:$v"
        else
            echo "    FAIL ubuntu:$v (see build/release-verify-$v.log)"
            grep -E 'FAIL|expected' "$BUILD/release-verify-$v.log" | head -5 | sed 's/^/         /'
            failed=1
        fi
    done
    [[ $failed == 0 ]] || die "verification failed"
    say "amd64 .deb verified on 20.04, 22.04, 24.04"
}

# ── publish ────────────────────────────────────────────────────────────────

# GitHub's artifact downloads time out on slow links; resume until complete.
download_artifact() { # <run id> <artifact name> <dest dir>
    local run="$1" name="$2" dest="$3" id url
    id="$(gh api "repos/$SRC_REPO/actions/runs/$run/artifacts" -q ".artifacts[] | select(.name==\"$name\") | .id")"
    [[ -n "$id" ]] || die "no artifact $name in run $run"
    mkdir -p "$dest"
    local i
    for i in $(seq 1 40); do
        url="$(curl -s -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $(gh auth token)" \
               "https://api.github.com/repos/$SRC_REPO/actions/artifacts/$id/zip")"
        curl -sS -L --connect-timeout 20 --speed-time 60 --speed-limit 1000 -C - \
             -o "$dest/$name.zip" "$url" && break
        say "  resuming $name ($(du -h "$dest/$name.zip" 2>/dev/null | cut -f1))"
    done
    ( cd "$dest" && unzip -o -q "$name.zip" && rm -f "$name.zip" )
}

stage_publish() {
    local version="$1" notes="$2"
    check_version "$version"
    [[ -f "$notes" ]] || die "release notes file '$notes' not found"
    [[ "$(current_version)" == "$version" ]] || die "app.h says $(current_version), not $version"
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/linux-$version" >/dev/null \
        || die "tag linux-$version missing (run prepare)"

    local branch sha
    branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
    sha="$(git -C "$REPO_ROOT" rev-parse "linux-$version^{commit}")"
    say "pushing $branch and linux-$version"
    git -C "$REPO_ROOT" push -q origin "$branch"
    git -C "$REPO_ROOT" push -q origin "linux-$version"

    say "waiting for the tag's CI run (builds, installs and types through both .debs)"
    local run="" i
    for i in $(seq 1 40); do
        run="$(gh run list --repo "$SRC_REPO" --commit "$sha" --json databaseId,headBranch \
               -q "[.[] | select(.headBranch==\"linux-$version\")][0].databaseId" 2>/dev/null || true)"
        [[ -n "$run" ]] && break
        sleep 15
    done
    [[ -n "$run" ]] || die "no CI run started for linux-$version"
    until [[ "$(gh run view "$run" --repo "$SRC_REPO" --json status -q .status 2>/dev/null)" == completed ]]; do
        sleep 30
    done
    gh run view "$run" --repo "$SRC_REPO" --json jobs -q '.jobs[] | "    \(.conclusion)\t\(.name)"'
    [[ "$(gh run view "$run" --repo "$SRC_REPO" --json conclusion -q .conclusion)" == success ]] \
        || die "CI run $run did not pass"

    local dest="$BUILD/release-$version"
    rm -rf "$dest"
    local arch
    for arch in amd64 arm64; do
        say "downloading the $arch .deb"
        download_artifact "$run" "byakaron-$arch" "$dest"
        local deb="$dest/byakaron_${version}_${arch}.deb"
        [[ -f "$deb" ]] || die "$deb missing from the artifact"
        [[ "$(dpkg-deb -f "$deb" Package)" == byakaron ]] || die "$deb: wrong package"
        [[ "$(dpkg-deb -f "$deb" Version)" == "$version" ]] || die "$deb: says $(dpkg-deb -f "$deb" Version)"
        [[ "$(dpkg-deb -f "$deb" Architecture)" == "$arch" ]] || die "$deb: wrong architecture"
    done

    say "creating linux-$version on $ASSETS_REPO (Latest)"
    gh release create "linux-$version" "$dest/byakaron_${version}_amd64.deb" "$dest/byakaron_${version}_arm64.deb" \
        --repo "$ASSETS_REPO" --title "Linux $version" --notes-file "$notes" --latest >/dev/null

    [[ "$(gh api "repos/$ASSETS_REPO/releases/latest" -q .tag_name)" == "linux-$version" ]] \
        || die "linux-$version is not the latest release"
    for arch in amd64 arm64; do
        local want got
        want="sha256:$(sha256sum "$dest/byakaron_${version}_${arch}.deb" | cut -d' ' -f1)"
        got="$(gh api "repos/$ASSETS_REPO/releases/latest" \
               -q ".assets[] | select(.name==\"byakaron_${version}_${arch}.deb\") | .digest")"
        [[ "$got" == "$want" ]] || die "$arch upload checksum mismatch ($got vs $want)"
        echo "    ok   byakaron_${version}_${arch}.deb ${want:7:16}…"
    done
    say "released: https://github.com/$ASSETS_REPO/releases/tag/linux-$version"
}

# ── website ────────────────────────────────────────────────────────────────

stage_website() {
    local version="$1" site="${2:-$HOME/Code/nuhulabs.com}"
    check_version "$version"
    [[ -d "$site/.git" || -f "$site/.git" ]] || die "no nuhulabs.com checkout at $site"
    [[ "$(current_version)" == "$version" ]] || die "app.h says $(current_version), not $version"

    git -C "$site" fetch -q origin
    local wt="$site-release-$version"
    rm -rf "$wt"
    git -C "$site" worktree prune
    git -C "$site" worktree add -q --detach "$wt" origin/main
    trap 'git -C "'"$site"'" worktree remove --force "'"$wt"'" 2>/dev/null || true' RETURN

    bash "$SCRIPT_DIR/site_installers.sh" "$wt/app/public/byakaron" >/dev/null
    if git -C "$wt" diff --quiet; then
        say "site installers already current"
    else
        git -C "$wt" add app/public/byakaron
        git -C "$wt" commit -q -m "chore(byakaron): Linux $version installers" \
            -m "Generated by byakaron platforms/linux/scripts/site_installers.sh (fallback linux-$version)."
        git -C "$wt" push -q origin HEAD:main
        local sha
        sha="$(git -C "$wt" rev-parse HEAD)"
        say "waiting for the site deploy"
        local run="" i
        for i in $(seq 1 40); do
            run="$(gh run list --repo "$SITE_REPO" --commit "$sha" --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
            [[ -n "$run" ]] && break
            sleep 15
        done
        [[ -n "$run" ]] || die "no deploy run for $sha"
        until [[ "$(gh run view "$run" --repo "$SITE_REPO" --json status -q .status 2>/dev/null)" == completed ]]; do
            sleep 20
        done
        [[ "$(gh run view "$run" --repo "$SITE_REPO" --json conclusion -q .conclusion)" == success ]] \
            || die "site deploy $run failed"
    fi

    local f
    for f in install.sh install-amd64.sh install-arm64.sh; do
        curl -fsSL --max-time 30 "https://nuhulabs.com/byakaron/$f" | diff -q - "$wt/app/public/byakaron/$f" >/dev/null \
            || die "live $f does not match"
        echo "    ok   https://nuhulabs.com/byakaron/$f"
    done
    say "website up to date for $version"
}

# ── main ───────────────────────────────────────────────────────────────────

cmd="${1:-}"
shift || true
case "$cmd" in
    prepare) stage_prepare "${1:-}" "${2:-}" ;;
    verify)  stage_verify "${1:-}" ;;
    publish) stage_publish "${1:-}" "${2:-}" ;;
    website) stage_website "${1:-}" "${2:-}" ;;
    all)
        stage_prepare "${1:-}" "${2:-}"
        stage_verify "${1:-}"
        stage_publish "${1:-}" "${3:-}"
        stage_website "${1:-}" "${4:-}"
        ;;
    *)
        sed -n '5,33p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
