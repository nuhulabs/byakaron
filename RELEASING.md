# Releasing Byakaron

Releases are built by GitHub Actions (`.github/workflows/release.yml`) and
published on the public [`nuhulabs/Byakaron-Assets`](https://github.com/nuhulabs/Byakaron-Assets)
repository, because this repository is private and users could not download
from it.

## Cut a release

1. Bump the version where each platform writes it (the tag does not do this):
   - Linux: `apps/linux/scripts/release.sh prepare <version> "<summary>"`
     bumps `app.h`, `package_deb.sh`, the installer fallback and AppStream, and
     commits. It also creates a `linux-<version>` tag; delete that tag
     (`git tag -d linux-<version>`) if you are cutting a `v*` release.
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
   | `byakaron_<ver>_amd64.deb`, `byakaron_<ver>_arm64.deb` | `cd.yml` (`package_deb.sh`, installed and tested on both CPUs) |
   | `Byakaron.dmg` | `zig build release-macos` on macos-14 |
   | `Byakaron-Setup.exe` | `zig build windows` (Inno Setup) on windows-latest |
   | `Byakaron.apk` | `./gradlew :app:assembleRelease` in the submodule, with freshly built `libbyakaron.so` and `spell.db` |
   | `spell.db` | `cd.yml` (`zig build db`, cached on its inputs) |
   | `SHA256SUMS` | the `publish` job, which also checks each upload's digest against it |

   Without `BYAKARON_ANDROID_TOKEN` the release goes out without the APK (the
   run shows a warning).

### Dry run

Run the `release` workflow by hand (Actions → release → Run workflow, or
`gh workflow run release.yml --ref <branch>`). It builds everything and leaves
the assets as the run's artifacts (`release-macos`, `release-windows`,
`release-android`, `byakaron-<arch>`, `spell-db`); nothing is published.

### Linux-only releases

The older flow still works: `apps/linux/scripts/release.sh all <version> …`
pushes a `linux-<version>` tag, which runs only `cd.yml` in `release.yml`;
release.sh then downloads the .debs from that run and creates the
`linux-<version>` release on `nuhulabs/Byakaron-Assets` from your machine.

## Secrets

Set these in this repository's Settings → Secrets and variables → Actions.
Only `BYAKARON_ASSETS_TOKEN` is required to publish; every other secret is
optional and its step is skipped when it is missing, so the assets are
**unsigned** until the signing secrets are added.

| Secret | Used by | What it is |
| --- | --- | --- |
| `BYAKARON_ASSETS_TOKEN` | `release.yml` publish | PAT (fine-grained: Contents read/write on `nuhulabs/Byakaron-Assets`) to create the release and upload assets. |
| `BYAKARON_ANDROID_TOKEN` | `ci.yml` android, `release.yml` android | PAT with Contents read on `nuhulabs/byakaron-android`, to check out the private `apps/android/keyboard` submodule. Without it CI builds only `libbyakaron.so` and releases have no APK. |
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

## CI

`ci.yml` runs on every push and pull request: the Linux engine/app/IME tests
(amd64 + arm64) and GNOME Wayland typing, `zig build test` on Ubuntu and macOS,
`zig build macos` (with a one-page bnwiki dump, `.github/ci/bnwiki-tiny.xml`,
so the bundled spell.db builds in seconds), `zig build windows`, the Android
`libbyakaron.so` for arm64-v8a / armeabi-v7a / x86_64 plus the debug APK (when
`BYAKARON_ANDROID_TOKEN` is set), and the web app (`zig build`).
