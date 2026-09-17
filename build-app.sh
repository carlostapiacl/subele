#!/bin/bash
# Arma "Audio Booster.app" a mano. SwiftPM no genera bundles y este proyecto se
# compila sin Xcode, así que la estructura y el Info.plist se escriben acá.
#
# El ícono también se genera: es código (Tools/make-icon.swift), no un binario
# commiteado, así que se puede revisar en diff como cualquier otro archivo.
set -euo pipefail
cd "$(dirname "$0")"

APP="Audio Booster.app"
ID="cl.carlostapia.audio-booster"
# Una sola fuente de verdad para la versión: la del código.
VERSION=$(sed -n 's/.*let version = "\(.*\)"/\1/p' Sources/BoosterKit/Booster.swift)

# Universal: arm64 + x86_64 en un solo binario.
#
# Sin esto el .dmg solo sirve en la arquitectura de quien lo compiló, y los
# runners de GitHub son Apple Silicon — o sea que la release quedaba rota en toda
# Mac Intel, con el mensaje inútil "no tiene el formato de ejecutable correcto".
#
# Se compila una arquitectura por vez y se unen con lipo, en vez de usar
# `swift build --arch a --arch b`: esa forma necesita xcbuild, que viene con Xcode
# completo, y este proyecto se compila con las Command Line Tools solas.
build_arch () {   # $1 = arquitectura
    local triple="$1-apple-macosx14.2"
    echo "   $1…"
    swift build -c release --scratch-path ".build-$1" \
        -Xswiftc -target -Xswiftc "$triple" \
        -Xcc -target -Xcc "$triple" >/dev/null
}

echo "▸ Compilando release (universal)…"
build_arch x86_64
build_arch arm64

echo "▸ Tests…"
swift test

echo "▸ Generando el ícono…"
swift Tools/make-icon.swift
iconutil -c icns Tools/AppIcon.iconset -o Tools/AppIcon.icns

echo "▸ Armando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    ".build-x86_64/release/booster" \
    ".build-arm64/release/booster" \
    -output "$APP/Contents/MacOS/booster"
cp Tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Audio Booster</string>
    <key>CFBundleDisplayName</key><string>Audio Booster</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleExecutable</key><string>booster</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <!-- Barra de menú: sin ícono en el Dock ni en cmd-tab -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- La interfaz trae inglés y español, y el selector del menú manda sobre esto -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>es</string></array>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audio Booster procesa el audio del sistema para subir el volumen sin distorsión.</string>
</dict>
</plist>
PLIST

# Firma ad-hoc: alcanza para correrla en la máquina que la compiló. Distribuirla
# pediría un certificado Developer ID y notarización — ver README.
echo "▸ Firmando (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/   /'

echo "▸ Verificando…"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
lipo -archs "$APP/Contents/MacOS/booster" | sed 's/^/   arquitecturas: /'

echo
echo "  Listo:   $(pwd)/$APP"
echo "  Abrir:   open '$APP'"
echo "  Consola: '$APP/Contents/MacOS/booster' --cli"
