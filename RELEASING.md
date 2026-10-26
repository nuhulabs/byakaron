# Releasing Byakaron

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Binaries
go on the public [`nuhulabs/Byakaron-Assets`](https://github.com/nuhulabs/Byakaron-Assets)
repo; this source repo gets a matching GitHub Release with notes only (and a
link to Assets).

## Cut a release

1. Bump the version where each platform writes it (the tag does not do this):
   - Linux, by hand (there is no release script): `.version` in
     `build.zig.zon` (the `.deb` control Version), `BYK_APP_VERSION` in
     `apps/linux/App/app.h`, `<version>` in `apps/linux/Resources/byakaron.xml.in`,
     and a `<release>` entry in the AppStream metainfo.
   - macOS: `CFBundleShortVersionString` in the Xcode project.
   - Android: `versionName` / `versionCode` in `apps/android/keyboard/app/build.gradle.kts`
     (in the submodule; push it, then commit the submodule bump here).
   - Windows takes its version from the tag (`BYAKARON_VERSION`).
2. Tag and push. The annotated tag's message becomes the release notes:

   ```sh
   git tag -a v0.3.0 -m "Byakaron 0.3.0" -m "What changed…"
   git push origin main v0.3.0
   ```

   A tag with a `-` (`v0.3.0-rc.1`) is published as a prerelease; any other
   tag becomes the Latest release.
3. Watch the `release` run. When every job passes:

   - **Byakaron-Assets** gets release `v0.3.0` with stable asset names (so
     `/releases/latest/download/…` never needs a version bump on the website):

   | Asset | Built by |
   | --- | --- |
   | `byakaron_amd64.deb`, `byakaron_arm64.deb` | `zig build package-linux` (renamed at publish) |
   | `Byakaron.dmg` | `zig build release-macos` |
   | `Byakaron-Setup.exe` | `zig build windows` |
   | `Byakaron.apk`, `Byakaron.aab` | `zig build release-android` |
   | `SHA256SUMS` | the `publish` job |

   - **byakaron** (this repo) gets the same tag as a notes-only GitHub Release.

   `Byakaron.db` is still built in prepare and embedded in the installers; it is
   not uploaded to Byakaron-Assets. The Worker / `/download` page is not
   redeployed on release — links already point at `latest`.

### Dry run

Run the `release` workflow by hand (Actions → release → Run workflow, or
`gh workflow run release.yml --ref <branch>`). It builds everything and leaves
the assets as the run's artifacts; nothing is published.

### Website installers

`apps/web/app/public/install.sh` (Linux + macOS) and `install.ps1` (Windows) are
served at `/install.sh` and `/install.ps1` on the Worker. They always pull from
Byakaron-Assets `releases/latest`. The `/download` page shows the one-liners.
`apps/linux/web_install.sh` remains a Linux-only fallback for older links.

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
