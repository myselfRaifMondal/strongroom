#!/usr/bin/env bash
# Creates a throwaway vault on a connected device or emulator, adds a fixed set
# of items, and exports a VTF (cross-platform round-trip, Phase 3).
#
# Usage:
#   scripts/export-vtf.sh <out-dir> <master-password>
#
# Writes <out-dir>/android.vtf, android.secret-key.txt, android.titles.txt.
# The debug app and androidTest APKs must already be installed.
#
# Env: ADB (default: adb on PATH, else $ANDROID_HOME/platform-tools/adb),
#      ANDROID_SERIAL to pick a device.
set -euo pipefail

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"

if [ $# -ne 2 ]; then
  sed -n '2,12p' "$0" >&2
  exit 2
fi
OUT_DIR="$1"; PASSWORD="$2"
mkdir -p "$OUT_DIR"

OUT="$("$ADB" shell am instrument -w \
  -e class app.strongroom.android.ExportVtfProbe \
  -e passwordB64 "$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')" \
  app.strongroom.android.test/androidx.test.runner.AndroidJUnitRunner 2>&1 || true)"

lines() { printf '%s\n' "$OUT" | tr -d '\r' | grep -oE "$1 .*" | sed -E "s/^$1 //"; }

if ! printf '%s\n' "$OUT" | grep -q 'SR_EXPORT_DONE' || ! printf '%s\n' "$OUT" | grep -qE '^OK \('; then
  echo "--- export failed; raw instrumentation output:" >&2
  printf '%s\n' "$OUT" | grep -v 'SR_EXPORT_B64' >&2
  exit 1
fi

lines SR_EXPORT_B64 | tr -d '\n' | base64 --decode > "$OUT_DIR/android.vtf"
lines SR_EXPORT_SECRET_KEY > "$OUT_DIR/android.secret-key.txt"
lines SR_EXPORT_TITLE > "$OUT_DIR/android.titles.txt"
chmod 600 "$OUT_DIR"/android.*

want="$(lines SR_EXPORT_DONE | sed -E 's/bytes=//')"
got="$(wc -c < "$OUT_DIR/android.vtf" | tr -d ' ')"
[ "$want" = "$got" ] || { echo "size mismatch: probe said $want, decoded $got" >&2; exit 1; }
echo "exported $got bytes to $OUT_DIR/android.vtf"
cat "$OUT_DIR/android.titles.txt" | sed 's/^/TITLE: /'
