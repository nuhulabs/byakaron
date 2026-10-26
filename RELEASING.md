# Releasing Byakaron

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published on the public [`nuhulabs/Byakaron-Assets`](https://github.com/nuhulabs/Byakaron-Assets)
repository, so installers stay downloadable when this source repo is private.

## Cut a release

1. Bump the version where each platform writes it (the tag does not do this):
   - Linux, by hand (there is no release script): `.version` in
     `build.zig.zon` (the `.deb` version), `BYK_APP_VERSION` in
     `apps/linux/App/app.h`, `<version>` in `apps/linux/Resources/byakaron.xml.in`,
     `VERSION_FALLBACK` in `apps/linux/web_install.sh`, and a `<release>` entry
     in the AppStream metainfo.
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
   tag becomes the Latest release, which the Linux web installer reads.
3. Watch the `release` run. When every job passes, `publish` creates the
   release `v0.3.0` on `nuhulabs/Byakaron-Assets` with:

   | Asset | Built by |
   | --- | --- |
   | `byakaron_<ver>_amd64.deb`, `byakaron_<ver>_arm64.deb` | `zig build package-linux` |
   | `Byakaron.dmg` | `zig build release-macos` |
   | `Byakaron-Setup.exe` | `zig build windows` |
   | `Byakaron.apk`, `Byakaron.aab` | `zig build release-android` |
   | `SHA256SUMS` | the `publish` job |

   `Byakaron.db` is still built in prepare and embedded in the installers; it is
   not uploaded to Byakaron-Assets.

   Then `deploy-web` refreshes `apps/web/app/downloads.zon` (links on `/download`)
   and redeploys the Worker.

### Dry run

Run the `release` workflow by hand (Actions → release → Run workflow, or
`gh workflow run release.yml --ref <branch>`). It builds everything and leaves
the assets as the run's artifacts; nothing is published.

### Linux website installer

The website installer is `apps/linux/web_install.sh`. It always installs the
Latest release from Byakaron-Assets. After a release, copy it by hand to
`app/public/byakaron/install.sh` in the nuhulabs.com repo when needed.

## Secrets

| Secret | Used by | What it is |
| --- | --- | --- |
| `BYAKARON_ASSETS_TOKEN` | `release.yml` publish | PAT with Contents write on `nuhulabs/Byakaron-Assets`. |
| `ANDROID_DEPLOY_KEY` | android pkg | Deploy key to clone `nuhulabs/byakaron-android`. |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | web deploy | Worker deploy after catalog refresh. |
| Apple / Windows / Android signing secrets | optional | Unsigned assets if missing. |

## CI / CD

```
ci:  test → integration → e2e
cd:  prepare ∥ web deploy + linux install-matrix
release: prepare → pkg → Byakaron-Assets @ v${version} → refresh /download + deploy web
```
