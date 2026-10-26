#!/usr/bin/env bash
# After a GitHub Release is published, lock installers as Zig lazy deps and
# upload them to the Cloudflare R2 bucket the Worker serves at /downloads/*.
#
# Usage (from repo root, with dist/ already populated):
#   scripts/sync-prebuilt.sh v0.2.1 dist
#
# Needs: zig 0.17, gh, wrangler (CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID).
# GitHub release asset URLs cannot be zig-fetched (Content-Disposition:
# attachment), so we tar each file locally, `zig fetch --save` that tarball,
# then rewrite the dep URL to the R2 object once uploaded.
set -euo pipefail

TAG="${1:?usage: sync-prebuilt.sh <tag> <dist-dir>}"
DIST="${2:?usage: sync-prebuilt.sh <tag> <dist-dir>}"
VERSION="${TAG#v}"
BUCKET="${BYAKARON_DOWNLOADS_BUCKET:-byakaron-downloads}"
R2_PUBLIC_BASE="${BYAKARON_R2_PUBLIC_BASE:-}" # e.g. https://pub-xxx.r2.dev — optional
TARBALL_DIR="${RUNNER_TEMP:-/tmp}/byakaron-prebuilt-tarballs"
mkdir -p "$TARBALL_DIR"

[[ -d "$DIST" ]] || { echo "error: dist dir missing: $DIST" >&2; exit 1; }

# name:dist_file:pack_as  (pack_as is the name inside the tarball / zig package)
ITEMS=(
  "prebuilt_macos:Byakaron.dmg:Byakaron.dmg"
  "prebuilt_windows:Byakaron-Setup.exe:Byakaron-Setup.exe"
  "prebuilt_android_apk:Byakaron.apk:Byakaron.apk"
  "prebuilt_android_aab:Byakaron.aab:Byakaron.aab"
  "prebuilt_db:Byakaron.db:Byakaron.db"
  "prebuilt_linux_amd64:byakaron_${VERSION}_amd64.deb:byakaron_amd64.deb"
  "prebuilt_linux_arm64:byakaron_${VERSION}_arm64.deb:byakaron_arm64.deb"
)

remove_zon_dep() {
  python3 - "$1" <<'PY'
import pathlib, sys
name = sys.argv[1]
zon = pathlib.Path("build.zig.zon")
text = zon.read_text()
key = f".{name} = .{{"
start = text.find(key)
if start < 0:
    raise SystemExit(0)
# Walk braces from the `.{{` after `=`.
i = text.find(".{", start)
depth = 0
end = None
for j in range(i, len(text)):
    if text[j] == "{":
        depth += 1
    elif text[j] == "}":
        depth -= 1
        if depth == 0:
            end = j + 1
            break
if end is None:
    raise SystemExit(f"unclosed dep {name}")
while end < len(text) and text[end] in " \t":
    end += 1
if end < len(text) and text[end] == ",":
    end += 1
if end < len(text) and text[end] == "\n":
    end += 1
zon.write_text(text[:start] + text[end:])
PY
}

echo ">>> packing + zig fetch (lazy prebuilts)"
for item in "${ITEMS[@]}"; do
  IFS=':' read -r name file pack <<<"$item"
  if [[ ! -f "$DIST/$file" ]]; then
    echo "  skip missing $file"
    continue
  fi
  stage="$TARBALL_DIR/stage-$name"
  rm -rf "$stage" && mkdir -p "$stage"
  cp "$DIST/$file" "$stage/$pack"
  tar -C "$stage" -czf "$TARBALL_DIR/${name}.tar.gz" "$pack"
  remove_zon_dep "$name"
  zig fetch --save="$name" "$TARBALL_DIR/${name}.tar.gz"
done

# Force .lazy = true on every prebuilt_* dep.
python3 <<'PY'
import pathlib
zon = pathlib.Path("build.zig.zon")
text = zon.read_text()
out = []
i = 0
while True:
    key_at = text.find(".prebuilt_", i)
    if key_at < 0:
        out.append(text[i:])
        break
    out.append(text[i:key_at])
    brace = text.find(".{", key_at)
    depth = 0
    end = None
    for j in range(brace, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    body = text[key_at:end]
    if ".lazy" in body:
        import re
        body = re.sub(r"\.lazy\s*=\s*(true|false)", ".lazy = true", body)
    else:
        body = body[:-1] + "    .lazy = true,\n        }"
    out.append(body)
    i = end
zon.write_text("".join(out))
print(">>> marked prebuilt_* deps as lazy")
PY

echo ">>> writing apps/web/app/downloads.zon"
python3 - "$VERSION" "$TAG" "$DIST" <<'PY'
import pathlib, sys, hashlib

version, tag, dist = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

# Prefer SHA256SUMS from the release publish step when present.
sums: dict[str, str] = {}
sums_path = dist / "SHA256SUMS"
if sums_path.exists():
    for line in sums_path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            sums[parts[1]] = parts[0]

def sha256(path: pathlib.Path) -> str:
    if path.name in sums:
        return sums[path.name]
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

catalog = [
    ("macos", "macOS", "Apple Silicon & Intel · .dmg", f"Byakaron.dmg"),
    ("windows", "Windows", "x64 installer · .exe", "Byakaron-Setup.exe"),
    ("linux_amd64", "Linux (amd64)", "Ubuntu / Debian · .deb", f"byakaron_{version}_amd64.deb"),
    ("linux_arm64", "Linux (arm64)", "Ubuntu / Debian · .deb", f"byakaron_{version}_arm64.deb"),
    ("android_apk", "Android (APK)", "Sideload · .apk", "Byakaron.apk"),
    ("android_aab", "Android (Play bundle)", "Play Store · .aab", "Byakaron.aab"),
    ("db", "Spell database", "Shared · Byakaron.db", "Byakaron.db"),
]

out = [".{", f'    .version = "{version}",', f'    .tag = "{tag}",', "    .assets = .{"]
for id_, label, detail, file in catalog:
    path = dist / file
    if not path.exists():
        continue
    digest = sha256(path)
    out += [
        "        .{",
        f'            .id = "{id_}",',
        f'            .label = "{label}",',
        f'            .detail = "{detail}",',
        f'            .file = "{file}",',
        f'            .sha256 = "{digest}",',
        "        },",
    ]
out += ["    },", "}"]
pathlib.Path("apps/web/app/downloads.zon").write_text("\n".join(out) + "\n")
print("wrote apps/web/app/downloads.zon")
PY

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "::warning::CLOUDFLARE_API_TOKEN unset — skip R2 upload; /downloads/* will 404 until synced"
  exit 0
fi

echo ">>> ensuring R2 bucket $BUCKET"
npx --yes wrangler@4.100.0 r2 bucket create "$BUCKET" 2>/dev/null || true

echo ">>> uploading installers to R2 (CDN)"
for item in "${ITEMS[@]}"; do
  IFS=':' read -r name file pack <<<"$item"
  [[ -f "$DIST/$file" ]] || continue
  # CDN key = the public download filename (versioned .deb stays versioned).
  npx --yes wrangler@4.100.0 r2 object put "$BUCKET/$file" \
    --file="$DIST/$file" --remote
  npx --yes wrangler@4.100.0 r2 object put "$BUCKET/prebuilt/${name}.tar.gz" \
    --file="$TARBALL_DIR/${name}.tar.gz" --remote
done

# Point dep URLs at R2 when a public base is configured (hash stays the same).
if [[ -n "$R2_PUBLIC_BASE" ]]; then
  echo ">>> rewriting prebuilt_* URLs → $R2_PUBLIC_BASE/prebuilt/"
  python3 - "$R2_PUBLIC_BASE" <<'PY'
import pathlib, re, sys
base = sys.argv[1].rstrip("/")
zon = pathlib.Path("build.zig.zon")
text = zon.read_text()
out = []
i = 0
while True:
    key_at = text.find(".prebuilt_", i)
    if key_at < 0:
        out.append(text[i:])
        break
    out.append(text[i:key_at])
    name = text[key_at + 1 : text.find(" ", key_at)]
    brace = text.find(".{", key_at)
    depth = 0
    end = None
    for j in range(brace, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                end = j + 1
                break
    body = text[key_at:end]
    url = f"{base}/prebuilt/{name}.tar.gz"
    body = re.sub(r'\.url\s*=\s*"[^"]*"', f'.url = "{url}"', body)
    out.append(body)
    i = end
zon.write_text("".join(out))
PY
fi

echo ">>> prebuilt sync done"
