#!/bin/bash
# Compila TP Optimizer, lo firma con tu certificado local y lo instala en /Applications.
# Uso: bash build.sh [versión]   Variables: SIGN_IDENTITY (por defecto "TP Optimizer Local"), INSTALL_DIR (por defecto /Applications)
set -euo pipefail
cd "$(dirname "$0")"

NAME="${SIGN_IDENTITY:-TP Optimizer Local}"
HASH=$(security find-identity -p codesigning | awk -v n="\"$NAME\"" '$0 ~ n {print $2; exit}')
if [ -z "$HASH" ]; then
  echo "No encuentro el certificado de firma \"$NAME\"."
  echo "Créalo: Acceso a Llaveros > Asistente de certificados > Crear un certificado > Tipo: Firma de código."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R *.swift helper Info.plist Resources "$WORK/"
sed -i '' "s/SIGNING_HASH/$(echo "$HASH" | tr 'A-F' 'a-f')/" "$WORK/Root.swift" "$WORK/helper/tp-root.swift"

APP="$WORK/TP Optimizer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
(cd "$WORK" && xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx26.0 $(ls *.swift) -o "$APP/Contents/MacOS/Optimizer")
(cd "$WORK" && xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 helper/tp-root.swift -o "$APP/Contents/Resources/tp-root")
cp "$WORK/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/Resources/AppIcon.icns" "$WORK/Resources/tp-logo.png" "$APP/Contents/Resources/"
[ -n "${1:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string 'TP Optimizer lee tu router y los equipos de tu red. No envía nada afuera.'" \
  -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription 'TP Optimizer usa el Finder para vaciar la Papelera y System Events para reiniciar, solo cuando tú lo pides.'" "$PLIST" 2>/dev/null || true

xattr -cr "$APP"
codesign -s "$HASH" --force --identifier app.tpoptimizer.root "$APP/Contents/Resources/tp-root"
codesign -s "$HASH" --force --deep --identifier app.tpoptimizer "$APP"
codesign --verify --deep --strict "$APP"

DEST="${INSTALL_DIR:-/Applications}"
pkill -f "$DEST/TP Optimizer.app/Contents/MacOS" || true
sleep 1
rm -rf "$DEST/TP Optimizer.app"
ditto "$APP" "$DEST/TP Optimizer.app"
echo "Instalada en $DEST/TP Optimizer.app"
