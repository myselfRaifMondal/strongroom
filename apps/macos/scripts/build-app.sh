#!/usr/bin/env bash
# Builds the release binaries with SwiftPM, assembles out/Strongroom.app and
# ad-hoc signs it (no certificate, no notarization). Also leaves the CLI at
# out/strongroom-mac-cli. Run scripts/build-core.sh first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
VERSION="${STRONGROOM_VERSION:-0.1.0}"
BUILD="${STRONGROOM_BUILD:-1}"

[[ -f lib/libstrongroom_ffi.a ]] || { echo "lib/libstrongroom_ffi.a missing: run scripts/build-core.sh" >&2; exit 1; }

echo "==> swift build -c release"
swift build -c release --product Strongroom
swift build -c release --product strongroom-mac-cli
BIN="$(swift build -c release --show-bin-path)"

APP="$HERE/out/Strongroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Strongroom" "$APP/Contents/MacOS/Strongroom"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$HERE/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"  # scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Strongroom</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>app.strongroom.mac</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Strongroom</string>
    <key>CFBundleDisplayName</key><string>Strongroom</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Strongroom. Local-only password manager.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Strongroom Transfer File</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>app.strongroom.vtf</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.strongroom.vtf</string>
            <key>UTTypeDescription</key><string>Strongroom Transfer File</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>vtf</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc codesign (hardened runtime, no entitlements)"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" || true

cp "$BIN/strongroom-mac-cli" "$HERE/out/strongroom-mac-cli"
codesign --force --sign - --options runtime --timestamp=none "$HERE/out/strongroom-mac-cli"

echo "==> built"
ls -l "$APP/Contents/MacOS/Strongroom" "$HERE/out/strongroom-mac-cli"
