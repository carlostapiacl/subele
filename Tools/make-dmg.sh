#!/bin/bash
# Empaqueta "Audio Booster.app" en un .dmg listo para descargar: la app y un
# atajo a Aplicaciones, que es el gesto que la gente ya conoce.
#
# Ojo con lo que esto NO hace: el .dmg va firmado ad-hoc y sin notarizar, porque
# notarizar exige una cuenta de Apple Developer de pago. macOS va a bloquear la
# app la primera vez que la abran. El README explica cómo destrabarla.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Audio Booster.app"
VERSION=$(sed -n 's/.*let version = "\(.*\)"/\1/p' Sources/BoosterKit/Booster.swift)
DMG="dist/audio-booster-${VERSION}.dmg"

[ -d "$APP" ] || { echo "No existe $APP — corré ./build-app.sh primero" >&2; exit 1; }

mkdir -p dist
rm -f "$DMG"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"

echo "▸ Creando ${DMG}…"
hdiutil create \
    -volname "Audio Booster" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo
echo "  Listo: $(pwd)/$DMG  (${SIZE})"
echo "  Probar: open '$DMG'"
