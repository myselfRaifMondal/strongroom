#!/usr/bin/env bash
# Imports a .vtf file into a fresh throwaway vault on a connected device or
# emulator and prints the imported item titles (cross-platform round-trip).
#
# Usage:
#   scripts/import-vtf.sh [--install] <file.vtf> <master-password> <secret-key>
#
#   --install   build (assembleDebug + assembleDebugAndroidTest) and install
#               both APKs first. Without it they must already be installed.
#
# Env: ADB (default: adb on PATH, else $ANDROID_HOME/platform-tools/adb),
#      ANDROID_SERIAL to pick a device.
#
# Output: the SR_IMPORT_* lines from ImportVtfProbe, e.g.
#   SR_IMPORT_SUMMARY added=3 updated=0 unchanged=0 conflicts=0
#   SR_IMPORT_TITLE GitHub
# Exit status is non-zero if the import failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$HERE/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"

INSTALL=0
if [ "${1:-}" = "--install" ]; then INSTALL=1; shift; fi
if [ $# -ne 3 ]; then
  sed -n '2,13p' "$0" >&2
  exit 2
fi
VTF="$1"; PASSWORD="$2"; SECRET_KEY="$3"
[ -f "$VTF" ] || { echo "no such file: $VTF" >&2; exit 2; }

if [ "$INSTALL" = 1 ]; then
  (cd "$ANDROID_DIR" && ./gradlew --quiet assembleDebug assembleDebugAndroidTest)
  "$ADB" install -r -t "$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk" >/dev/null
  "$ADB" install -r -t "$ANDROID_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" >/dev/null
fi

REMOTE=/data/local/tmp/strongroom-import.vtf
"$ADB" push "$VTF" "$REMOTE" >/dev/null
"$ADB" shell chmod 644 "$REMOTE"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

OUT="$("$ADB" shell am instrument -w \
  -e class app.strongroom.android.ImportVtfProbe \
  -e vtf "$REMOTE" \
  -e passwordB64 "$(b64 "$PASSWORD")" \
  -e secretKeyB64 "$(b64 "$SECRET_KEY")" \
  app.strongroom.android.test/androidx.test.runner.AndroidJUnitRunner 2>&1 || true)"

"$ADB" shell rm -f "$REMOTE" >/dev/null 2>&1 || true

printf '%s\n' "$OUT" | grep -E '^SR_IMPORT_' || true
if printf '%s\n' "$OUT" | grep -q '^SR_IMPORT_SUMMARY' && printf '%s\n' "$OUT" | grep -qE '^OK \('; then
  exit 0
fi
echo "--- import failed; raw instrumentation output:" >&2
printf '%s\n' "$OUT" | tail -n 30 >&2
exit 1
