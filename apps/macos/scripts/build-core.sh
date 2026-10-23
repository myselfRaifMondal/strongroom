#!/usr/bin/env bash
# Builds the Rust core (strongroom-ffi) for this Mac and generates the Swift
# bindings the package compiles against:
#
#   lib/libstrongroom_ffi.a                          static library (linked)
#   Sources/strongroomFFI/strongroomFFI.h            C declarations
#   Sources/StrongroomKit/Generated/strongroom.swift Swift bindings
#
# The UDL contract is frozen; this script only consumes it.
# Env: CARGO_JOBS (default 2: the dev Mac has 8 GB), CARGO_TARGET_DIR.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
JOBS="${CARGO_JOBS:-2}"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}"
# Match Package.swift's platform so C code in the core (SQLCipher, vendored
# OpenSSL) is not built for the SDK's newer macOS version.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT

cd "$REPO"
echo "==> cargo build -p strongroom-ffi --release (-j $JOBS)"
cargo build -j "$JOBS" -p strongroom-ffi --release

LIB="$TARGET_DIR/release"
# Snapshot the library now: the bindgen run below rebuilds strongroom-ffi with
# the `bindgen` feature into the same target directory.
cp "$LIB/libstrongroom_ffi.a" "$LIB/libstrongroom_ffi.dylib" "$GEN/"

echo "==> uniffi-bindgen generate --language swift"
# --release so the bindgen binary reuses the release build of the core's
# dependencies (SQLCipher + vendored OpenSSL) instead of a debug rebuild.
mkdir -p "$GEN/out"
cargo run --release -j "$JOBS" -q -p strongroom-ffi --features bindgen --bin uniffi-bindgen -- \
    generate --library "$GEN/libstrongroom_ffi.dylib" --language swift --out-dir "$GEN/out"

mkdir -p "$HERE/lib" "$HERE/Sources/StrongroomKit/Generated"
# Only the static archive goes in lib/, so the linker cannot pick the dylib.
cp "$GEN/libstrongroom_ffi.a" "$HERE/lib/libstrongroom_ffi.a"
cp "$GEN/out/strongroomFFI.h" "$HERE/Sources/strongroomFFI/strongroomFFI.h"
cp "$GEN/out/strongroom.swift" "$HERE/Sources/StrongroomKit/Generated/strongroom.swift"

echo "==> done"
ls -l "$HERE/lib/libstrongroom_ffi.a"
