#!/usr/bin/env bash
# Minimal adb/uiautomator driver for the Compose UI (testTags are exposed as
# resource-ids). Used for the emulator walkthrough.
#   ui-drive.sh ids                 list resource-ids on screen
#   ui-drive.sh texts               list visible texts
#   ui-drive.sh tap <id-or-text>    tap the element's centre
#   ui-drive.sh type <id> <text>    tap the field and type (no spaces; use %s)
#   ui-drive.sh has <id-or-text>    exit 0 if present
#   ui-drive.sh clear <id>          empty a text field
#   ui-drive.sh key <keycode...>    send key events (111 = Escape/hide IME)
set -euo pipefail
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"

dump() {
  "$ADB" shell uiautomator dump /sdcard/sr-ui.xml >/dev/null 2>&1
  "$ADB" shell cat /sdcard/sr-ui.xml
}

center() {
  dump | python3 -c '
import re, sys
x = sys.stdin.read(); key = sys.argv[1]
for m in re.finditer(r"<node [^>]*>", x):
    n = m.group(0)
    if f"resource-id=\"{key}\"" in n or f"text=\"{key}\"" in n:
        b = list(map(int, re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", n).groups()))
        print((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
        break
' "$1"
}

case "${1:-}" in
  ids) dump | grep -o 'resource-id="[^"]*"' | grep -v 'resource-id=""' | sort -u ;;
  texts) dump | grep -o 'text="[^"]*"' | grep -v 'text=""' ;;
  has) [ -n "$(center "$2")" ] ;;
  tap)
    c="$(center "$2")"; [ -n "$c" ] || { echo "NOT FOUND: $2" >&2; exit 1; }
    # shellcheck disable=SC2086
    "$ADB" shell input tap $c ;;
  type)
    c="$(center "$2")"; [ -n "$c" ] || { echo "NOT FOUND: $2" >&2; exit 1; }
    # shellcheck disable=SC2086
    "$ADB" shell input tap $c
    sleep 0.4
    "$ADB" shell input text "$3" ;;
  clear)
    c="$(center "$2")"; [ -n "$c" ] || { echo "NOT FOUND: $2" >&2; exit 1; }
    # shellcheck disable=SC2086
    "$ADB" shell input tap $c
    sleep 0.4
    "$ADB" shell input keycombination 113 29   # Ctrl+A
    "$ADB" shell input keyevent 67 ;;          # Del
  key) shift; "$ADB" shell input keyevent "$@" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
