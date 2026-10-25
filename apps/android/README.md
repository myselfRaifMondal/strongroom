# Strongroom for Android

Jetpack Compose app over the Rust core (`crates/strongroom-ffi`, UniFFI 0.31.0,
Kotlin bindings generated from the frozen UDL, loaded through JNA).

- **minSdk 26** (Android 8.0): Autofill framework and Keystore EC keys.
  Hardware ECDH (`PURPOSE_AGREE_KEY`) is API 31, so biometric unlock and
  device-bound export/import are enabled only on **API >= 31**; below that the
  UI disables them with an explanation (OQ-1). Password unlock and
  password-protected VTF export/import work on every supported version.
- targetSdk/compileSdk 35, AGP 8.7.3, Kotlin 2.1.0, Gradle 8.10.2, JDK 17,
  NDK 27.2.12479018.
- No network permission (checked in CI). No backup (`allowBackup=false`).
  `FLAG_SECURE` on every activity window. Clipboard copies are marked
  sensitive and cleared after 25 s.

## Build

    rustup target add aarch64-linux-android x86_64-linux-android
    cargo install cargo-ndk
    cd apps/android
    ./gradlew assembleDebug        # runs scripts/build-rust.sh first

`STRONGROOM_ABIS` (default `arm64-v8a`) and `STRONGROOM_RUST_PROFILE`
(`debug`/`release`) control the Rust build; `-Pstrongroom.skipRust=true` skips
it when the `.so` and bindings already exist.

## Scripts

- `scripts/build-rust.sh` - cargo-ndk build + uniffi-bindgen Kotlin bindings.
- `scripts/import-vtf.sh [--install] <file.vtf> <password> <secret-key>` -
  imports a VTF into a throwaway vault on the connected device/emulator via
  the `ImportVtfProbe` instrumentation test and prints `SR_IMPORT_TITLE` lines
  (cross-platform round-trip).
- `scripts/check-no-network.sh <apk>` - fails on any network permission.

## Tests

- `./gradlew testDebugUnitTest` - pure logic (master-password rule, CSV
  source detection, back-stack state, autofill field heuristics, SEC1, boot id).
- `./gradlew connectedDebugAndroidTest` - on a device/emulator whose screen
  is unlocked (after a reboot the user storage stays locked until the PIN is
  entered, and instrumentation cannot start): config-change handling, no
  network permission, sensitive + auto-cleared clipboard (takes ~30 s), CSV
  import for every supported exporter, plus the VTF probes (skipped without
  arguments).

## Autofill walkthrough on an emulator

The test APK (never the app APK) contains `AutofillTestActivity`, a login
form for trying the autofill service without a browser or network:

    adb shell settings put secure autofill_service \
        app.strongroom.android/.autofill.StrongroomAutofillService
    adb shell am start -n app.strongroom.android.test/app.strongroom.android.AutofillTestActivity --ez web true

The WebView form reports this app's package name (not a web domain) to the
autofill service, so the matching vault item needs the website
`app.strongroom.android.test`. Locked vaults show "Unlock Strongroom".

Saving: on the native form, type a username and password and tap "Sign
in". Android offers "Save username and password to Strongroom?" (or
"Update ..." for a known login). Accepting opens Strongroom, which unlocks
the vault if needed and shows the title, username and URL to confirm;
nothing is written before you tap Save or Update. Updating keeps the old
password in the item's history. The captured password stays in process
memory only until you answer.
