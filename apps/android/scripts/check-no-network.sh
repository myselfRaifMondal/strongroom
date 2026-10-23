#!/usr/bin/env bash
# Fails if the built APK requests any network permission (Strongroom is local-only).
set -euo pipefail
APK="${1:?usage: check-no-network.sh <apk>}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT2="$(ls -d "$SDK"/build-tools/*/aapt2 | sort -V | tail -n 1)"
PERMS="$("$AAPT2" dump permissions "$APK")"
echo "$PERMS"
if echo "$PERMS" | grep -E "uses-permission: name='android\.permission\.(INTERNET|ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE|CHANGE_NETWORK_STATE)'"; then
  echo "ERROR: network permission present in $APK" >&2
  exit 1
fi
echo "OK: no network permissions in $APK"
