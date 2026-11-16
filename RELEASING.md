# Releasing Byakaron

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Binaries
go on the public [`nuhulabs/Byakaron-Assets`](https://github.com/nuhulabs/Byakaron-Assets)
repo; this source repo gets a matching GitHub Release with notes only (and a
link to Assets).

## Cut a release

Between releases `build.zig.zon`'s `.version` is the next version's prerelease,
`27.0.0-dev`. To publish a dev build, run the `release` workflow with
**prerelease** checked and **version** empty (`gh workflow run release.yml -f
prerelease=true`): it tags the next `v27.0.0-dev.N` (one above the highest
existing N), builds every platform with that version and publishes it as a
prerelease. Nothing needs bumping.

For a real release:

1. Bump the version where each platform writes it (the tag does not do this):
   - Linux: `.version` in `build.zig.zon` (e.g. `27.0.0-dev` → `27.0.0`), plus a
     `<release>` entry with notes in the AppStream metainfo. The `.deb`,
     `byakaron --version` and the IBus component all take the zon version; the
     `.deb` adds epoch 1 itself (`1:27.0.0`), the Arch package its pkgrel
     (`27.0.0-1`). After the release, set it to the
     next prerelease (`28.0.0-dev`).
   - macOS: `CFBundleShortVersionString` in the Xcode project (`MARKETING_VERSION`).
   - Android: `versionName` / `versionCode` in `apps/android/keyboard/app/build.gradle.kts`
     (in the submodule; push it, then commit the submodule bump here).
   - Windows takes its version from the tag (`BYAKARON_VERSION`).
2. Tag and push. The annotated tag's message becomes the release notes:

   ```sh
   git tag -a v0.3.0 -m "Byakaron 0.3.0" -m "What changed…"
   git push origin main v0.3.0
   ```

   A tag with a `-` (`v0.3.0-rc.1`) is published as a prerelease; any other
   tag becomes the Latest release. A tag that does not match `build.zig.zon`
   stops the release in its `version` job. Dispatching the workflow with a
   **version** instead tags that version at the dispatched commit.
3. Watch the `release` run. When every job passes:

   - **Byakaron-Assets** gets release `v0.3.0` with stable asset names (so
     `/releases/latest/download/…` never needs a version bump on the website):

   | Asset | Built by |
   | --- | --- |
   | `byakaron_amd64.deb`, `byakaron_arm64.deb` | `zig build package-linux` (renamed at publish) |
   | `byakaron_x86_64.pkg.tar.zst` (Arch Linux) | `zig build package-linux-arch` (renamed at publish) |
   | `Byakaron.dmg` | `zig build release-macos` |
   | `Byakaron-Setup.exe` | `zig build windows` |
   | `Byakaron.apk`, `Byakaron.aab` | `zig build release-android` |
   | `SHA256SUMS` | the `publish` job |

   - **byakaron** (this repo) gets the same tag as a notes-only GitHub Release.

   `Byakaron.db` is still built in prepare and embedded in the installers; it is
   not uploaded to Byakaron-Assets. The Worker / `/download` page is not
   redeployed on release — links already point at `latest`.

### Dry run

Run the `release` workflow by hand with **prerelease** unchecked and **version**
empty (Actions → release → Run workflow, or `gh workflow run release.yml --ref
<branch>`). It builds everything and leaves the assets as the run's artifacts;
nothing is tagged or published.

### Website installers

The public command is `curl -fsSL https://nuhulabs.com/byakaron/install.sh | bash`.
`nuhulabs.com/byakaron/` is served by the **nuhulabs.com repo**, which keeps copies
in `app/public/byakaron/`: `install.sh` is `apps/web/app/public/install.sh` (Linux
+ macOS), and `install-amd64.sh` / `install-arm64.sh` (links shared earlier) are
`apps/linux/web_install.sh`. Copy them there when they change; that site deploys
on push. byakaron's Worker serves `install.sh` and `install.ps1` (Windows) and the
`/download` page at https://byakaron.nuhulabs.workers.dev. Every installer pulls
from Byakaron-Assets `releases/latest`, so a release itself needs no copy.

After publishing, `release.yml`'s `live-install` job runs the public command in
clean Ubuntu containers (amd64 and arm64) and fails unless it installs this release.

## Secrets

| Secret | Used by | What it is |
| --- | --- | --- |
| `BYAKARON_ASSETS_TOKEN` | `release.yml` publish | PAT with Contents write on `nuhulabs/Byakaron-Assets`. |
| `ANDROID_DEPLOY_KEY` | android pkg | Deploy key to clone `nuhulabs/byakaron-android`. |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | cd web deploy | Worker deploy on push to `main`. |
| Apple / Windows / Android signing secrets | optional | Unsigned assets if missing. |

## CI / CD

```
ci:  test → integration → e2e
cd:  prepare ∥ web deploy + linux install-matrix
release: prepare → pkg → Byakaron-Assets (binaries) + byakaron (notes)
```
