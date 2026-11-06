#!/bin/zsh
# Builds build/Ledge.app from source. Usage: scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Ledge.app
echo "• Compiling Ledge"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: |Compiling|Build" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Ledge"
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }

echo "• Compiling media bridge"
mkdir -p build
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework Foundation Bridge/MediaBridge.m -o build/MediaBridge.dylib

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  echo "• Drawing app icon"
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "• Assembling Ledge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ledge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp build/MediaBridge.dylib "$APP/Contents/Resources/MediaBridge.dylib"
cp Bridge/media-bridge.pl "$APP/Contents/Resources/media-bridge.pl"

# Sign with the personal "Ledge Local Signing" certificate when it's in the keychain, so
# macOS sees every build as the same app and keeps its permissions (Accessibility).
# Without it, fall back to an ad-hoc signature (permissions then reset on every build).
IDENTITY="Ledge Local Signing"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "  (no '$IDENTITY' certificate found; signing ad-hoc)"
  IDENTITY="-"
fi
echo "• Signing for this Mac"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/MediaBridge.dylib"
codesign --force --sign "$IDENTITY" --identifier local.sabir.ledge "$APP"
echo "✓ Built $APP"
