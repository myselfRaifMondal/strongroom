#!/usr/bin/env bash
# Builds libstrongroom_ffi.so for Android with cargo-ndk and generates the
# Kotlin bindings from the frozen UDL with uniffi-bindgen 0.31.0.
#
# Env:
#   STRONGROOM_ABIS          space-separated ABIs (default: "arm64-v8a")
#   STRONGROOM_RUST_PROFILE  debug | release (default: debug)
#   CARGO_BUILD_JOBS         cargo parallelism (default: 2)
#   ANDROID_NDK_HOME         NDK root (default: $ANDROID_HOME/ndk/27.2.12479018)
#
# Outputs (both git-ignored):
#   app/src/main/jniLibs/<abi>/libstrongroom_ffi.so
#   app/build/generated/uniffi/kotlin/uniffi/strongroom/strongroom.kt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$ANDROID_DIR/../.." && pwd)"

ABIS="${STRONGROOM_ABIS:-arm64-v8a}"
PROFILE="${STRONGROOM_RUST_PROFILE:-debug}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$SDK/ndk/27.2.12479018}"
MIN_SDK=26

if [ ! -d "$ANDROID_NDK_HOME" ]; then
  echo "NDK not found at $ANDROID_NDK_HOME" >&2
  exit 1
fi

cd "$REPO"

TARGET_ARGS=()
for abi in $ABIS; do TARGET_ARGS+=(-t "$abi"); done
RELEASE_ARG=()
if [ "$PROFILE" = "release" ]; then RELEASE_ARG=(--release); fi

# --locked: build exactly the crate versions in Cargo.lock (the ones CI tests
# and audits); fail instead of resolving new ones.
echo "==> cargo ndk ($ABIS, $PROFILE, jobs=$CARGO_BUILD_JOBS)"
cargo ndk "${TARGET_ARGS[@]}" --platform "$MIN_SDK" \
  -o "$ANDROID_DIR/app/src/main/jniLibs" \
  build --locked -p strongroom-ffi --lib "${RELEASE_ARG[@]+"${RELEASE_ARG[@]}"}"

echo "==> uniffi-bindgen (host) -> Kotlin"
cargo build --locked -p strongroom-ffi --features bindgen --bin uniffi-bindgen
OUT="$ANDROID_DIR/app/build/generated/uniffi/kotlin"
rm -rf "$OUT"
mkdir -p "$OUT"
"$REPO/target/debug/uniffi-bindgen" generate \
  "$REPO/crates/strongroom-ffi/src/strongroom.udl" \
  --language kotlin \
  --config "$ANDROID_DIR/uniffi.toml" \
  --no-format \
  --out-dir "$OUT"

echo "==> done"
ls -la "$ANDROID_DIR"/app/src/main/jniLibs/*/libstrongroom_ffi.so
