#!/usr/bin/env bash
# `swift test` that also works with only the Command Line Tools installed.
# The CLT ship swift-testing under a framework path SwiftPM does not search,
# and its Foundation cross-import overlay has no module; with Xcode selected
# (CI) plain `swift test` is used.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    F="$DEV_DIR/Library/Developer/Frameworks"
    exec swift test \
        -Xswiftc -F -Xswiftc "$F" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
