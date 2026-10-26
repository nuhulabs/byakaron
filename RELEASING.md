# Releasing Byakaron

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published as a GitHub Release on this repository (`nuhulabs/byakaron`).

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
   release `v0.3.0` on this repo with:

   | Asset | Built by |
   | --- | --- |
   | `byakaron_<ver>_amd64.deb`, `byakaron_<ver>_arm64.deb` | `zig build package-linux` (one `.deb` per CPU; Debian has no universal binary package) |
   | `Byakaron.dmg` | `zig build release-macos` on the `xcode-27` runner |
   | `Byakaron-Setup.exe` | `zig build windows` (Inno Setup) on windows-latest |
   | `Byakaron.apk`, `Byakaron.aab` | `zig build release-android` |
   | `Byakaron.db` | `zig build db` (prepare job) |
   | `SHA256SUMS` | the `publish` job, which also checks each upload's digest against it |

### Dry run

Run the `release` workflow by hand (Actions → release → Run workflow, or
`gh workflow run release.yml --ref <branch>`). It builds everything and leaves
the assets as the run's artifacts (`byakaron-macos`, `byakaron-windows`,
`byakaron-android`, `byakaron-linux-*`, `byakaron-db`); nothing is published.

### Linux website installer

The `.deb`s come from CI only. The website installer is `apps/linux/web_install.sh`.
After a release, copy it by hand to `app/public/byakaron/install.sh` in the
nuhulabs.com repo (and as `install-amd64.sh` / `install-arm64.sh` for links
shared earlier). It always installs the Latest release, so the page needs no
version bump.

## Secrets

Set these in this repository's Settings → Secrets and variables → Actions.
Publish uses `GITHUB_TOKEN` (no PAT). Other secrets are optional; their steps
are skipped when missing, so assets are **unsigned** until signing secrets are added.

| Secret | Used by | What it is |
| --- | --- | --- |
| `ANDROID_DEPLOY_KEY` | `pkg.yml` / `ci.yml` android | Deploy key to clone `nuhulabs/byakaron-android`. Without it CI builds only `libbyakaron.so` and releases have no APK. |
| `APPLE_CERTIFICATE` | `release.yml` macos | Base64 of the "Developer ID Application" certificate + key exported as `.p12` (`base64 -i cert.p12`). Its presence turns on signing and notarization. |
| `APPLE_CERTIFICATE_PASSWORD` | `release.yml` macos | Password of that `.p12`. |
| `APPLE_SIGNING_IDENTITY` | `release.yml` macos | The identity name, e.g. `Developer ID Application: Nuhu Labs (TEAMID)`. |
| `APPLE_ID` | `release.yml` macos | Apple ID email used for notarization. |
| `APPLE_TEAM_ID` | `release.yml` macos | Developer team ID. |
| `APPLE_APP_PASSWORD` | `release.yml` macos | App-specific password of that Apple ID, for `notarytool`. |
| `WINDOWS_CERTIFICATE` | `release.yml` windows | Base64 of the Authenticode code-signing `.pfx`. Its presence turns on signing of `Byakaron-Setup.exe`. |
| `WINDOWS_CERTIFICATE_PASSWORD` | `release.yml` windows | Password of that `.pfx`. |
| `ANDROID_KEYSTORE_BASE64` | `release.yml` android | Base64 of the release keystore (`.jks`). Its presence turns on APK signing. |
| `RELEASE_STORE_PASSWORD` | `release.yml` android | Keystore password. |
| `RELEASE_KEY_ALIAS` | `release.yml` android | Key alias in the keystore. |
| `RELEASE_KEY_PASSWORD` | `release.yml` android | Key password. |

Notes:

- macOS signing re-signs the app in the built image with the hardened runtime
  (keeping each bundle's entitlements), rebuilds the image, notarizes and
  staples it.
- Windows signing signs the installer only; the app and IME DLLs inside it stay
  unsigned.
- An unsigned release APK cannot be installed until it is signed.

## CI / CD

```
ci:  test (os) → integration (os) → e2e (os)
cd:  prepare (Byakaron.db) ∥ web deploy + linux install-matrix e2e
release: prepare → pkg (all os) → GitHub Release @ v${build.zig.zon.version}
```

Linux packaging is entirely `zig build` (`package-linux`, `linux-ci`,
`linux-wayland-e2e`, `linux-install-test`, …). The only remaining shell file
under `apps/linux/` is the public website installer `web_install.sh`.
