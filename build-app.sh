#!/bin/bash
# Builds "Audio Booster.app" by hand. SwiftPM does not produce bundles and this
# project is built without Xcode, so the layout and Info.plist are written out here.
set -euo pipefail
cd "$(dirname "$0")"

APP="Audio Booster.app"
ID="cl.carlostapia.audio-booster"
VERSION="0.1"

echo "▸ Building release…"
swift build -c release

echo "▸ Tests…"
swift test

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/booster "$APP/Contents/MacOS/booster"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Audio Booster</string>
    <key>CFBundleDisplayName</key><string>Audio Booster</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleExecutable</key><string>booster</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <!-- Barra de menú, sin ícono en el Dock ni en cmd-tab -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audio Booster procesa el audio del sistema para subir el volumen sin distorsión.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough to run it on the machine that built it. Distributing
# it would need a Developer ID certificate and notarisation — see the README.
echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/   /'

echo "▸ Verifying…"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'

echo
echo "  Built: $(pwd)/$APP"
echo "  Open:    open '$APP'"
echo "  Console: '$APP/Contents/MacOS/booster' --cli"
