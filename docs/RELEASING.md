# Releasing Strongroom

Releases are built by `.github/workflows/release.yml`. It never publishes
anything by itself: a tag push creates a **draft** pre-release that the
maintainer reviews and publishes by hand.

## What the workflow builds

| Platform | File | Built by |
|----------|------|----------|
| Windows x64, ARM64 | `Strongroom-Setup-<ver>-<arch>.exe`, `Strongroom-<ver>-<arch>-portable.zip` | `windows-installer.yml` (called by `release.yml`) |
| Android | `Strongroom-<ver>-android-arm64-v8a.apk` | `release.yml`, job `android` |
| macOS | `Strongroom-<ver>-macos-arm64.zip` | `release.yml`, job `macos` |
| all | `SHA256SUMS.txt` | `release.yml`, job `release` |

A file that was not signed has `-unsigned` before its extension, for
example `Strongroom-Setup-0.2.0-x64-unsigned.exe`. The macOS "unsigned" zip
is ad-hoc signed only (not Developer ID, not notarized). The release notes
say which platforms are signed and that the software is pre-release and not
independently audited.

## Dry run

Run **Actions > release > Run workflow** on any branch. It builds and signs
(if configured) everything and keeps the files as the workflow artifact
`strongroom-release-<ver>`. It creates no tag and no release.

## Making a release

1. Make sure `main` is green.
2. Tag the commit: `git tag -s v0.2.0 -m "Strongroom 0.2.0"` and
   `git push origin v0.2.0`.
3. Wait for the `release` workflow. It creates a draft pre-release for the
   tag with every file and `SHA256SUMS.txt`.
4. Check the draft: file list, signatures, notes. Then publish it by hand.

The Android `versionName` and `versionCode` come from
`apps/android/app/build.gradle.kts`, not from the tag. Bump them there
before tagging.

## Signing

Each signing step runs only when all of its secrets (and variables) are
set. Without them the build still succeeds and the files are named
`-unsigned`. Pull requests never sign, even when the secrets are set,
because GitHub gives repository secrets to pull requests from branches in
this repository. Forks get no secrets, so they build unsigned too. Other runs
(tag pushes, manual `workflow_dispatch` runs, and branch pushes that start
`windows-installer.yml`) sign when the secrets are set. The
workflows check whether a secret is set without printing it.

Add secrets under **Settings > Secrets and variables > Actions**. **Never**
commit a certificate, key, keystore or password to the repository.

### Windows: Azure Trusted Signing (#27)

Signs Strongroom's own `.exe`/`.dll` files and both installers, then checks
them with `Get-AuthenticodeSignature`. Login uses OpenID Connect (a
federated credential on an Entra app registration for this repository), so
no Azure password is stored.

| Name | Kind | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | secret | app registration (client) ID |
| `AZURE_TENANT_ID` | secret | tenant ID |
| `AZURE_SUBSCRIPTION_ID` | secret | subscription that holds the signing account |
| `WINDOWS_SIGNING_ENDPOINT` | variable | e.g. `https://eus.codesigning.azure.net/` |
| `WINDOWS_SIGNING_ACCOUNT` | variable | Trusted Signing account name |
| `WINDOWS_SIGNING_PROFILE` | variable | certificate profile name |

The app registration needs the certificate profile signer role on the
signing account (see Microsoft's Trusted Signing, now Artifact Signing, docs). The uninstaller inside the installer is not
signed yet (Inno Setup's `SignTool=` needs a signer on the build machine).

### Android: release keystore

`apps/android/app/build.gradle.kts` reads the `STRONGROOM_ANDROID_KEYSTORE*`
variables. The workflow decodes the keystore to a temporary file, builds,
deletes it, and verifies the APK with `apksigner`.

| Secret | Value |
|--------|-------|
| `STRONGROOM_ANDROID_KEYSTORE_BASE64` | the keystore file, base64 (`base64 -i release.jks`) |
| `STRONGROOM_ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `STRONGROOM_ANDROID_KEY_ALIAS` | optional, default `strongroom` |
| `STRONGROOM_ANDROID_KEY_PASSWORD` | optional, default is the keystore password |

Android will not install an unsigned APK, so testers need a signed one.
Keep a backup of the keystore: updates must be signed with the same key.

### macOS: Developer ID and notarization (#18)

The workflow imports the certificate into a temporary keychain on the
runner, signs `Strongroom.app` with the hardened runtime and a timestamp,
notarizes it with an App Store Connect API key, staples the ticket and
checks it with `spctl`. The keychain and key files are deleted afterwards.

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12_BASE64` | "Developer ID Application" certificate + private key as .p12, base64 |
| `MACOS_CERTIFICATE_PASSWORD` | password of the .p12 |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `MACOS_NOTARY_KEY_P8_BASE64` | App Store Connect API key (.p8), base64 |
| `MACOS_NOTARY_KEY_ID` | key ID of that API key |
| `MACOS_NOTARY_ISSUER_ID` | issuer ID of that API key |

Only an arm64 build is made today (the `macos-latest` runner is Apple
silicon).

## Not verified yet

None of the signing paths has run with real credentials. The first signed
release should be checked by hand: the Windows UAC prompt shows the
publisher, the Android APK installs over a previous signed build, and the
macOS zip opens without a Gatekeeper warning on a clean Mac.
