#!/bin/zsh
# Builds build/Ledge.app from source. Usage: scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Ledge.app
mkdir -p build
echo "• Compiling Ledge"
# Stop here if the build fails, so an old copy is never installed by mistake.
if ! swift build -c release --arch arm64 > build/swift-build.log 2>&1; then
  grep -E "error" build/swift-build.log | head -20
  echo "✗ Build failed (see build/swift-build.log)"
  exit 1
fi
grep -E "warning: " build/swift-build.log | head -10 || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Ledge"

echo "• Compiling media bridge"
mkdir -p build
clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
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
# Record which saved version this build came from ("+" means it has unsaved changes too).
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && COMMIT="$COMMIT+"
/usr/libexec/PlistBuddy -c "Add :LedgeCommit string $COMMIT" "$APP/Contents/Info.plist"
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
sign() {
  if ! codesign --force --sign "$IDENTITY" "$@" > build/sign.log 2>&1; then
    cat build/sign.log
    if grep -q "errSecInternalComponent" build/sign.log; then
      echo "✗ Signing failed: macOS asked whether codesign may use the '$IDENTITY' key, and it wasn't allowed in time."
      echo "  Run this once (it asks for your Mac password), then build again; it won't ask again:"
      echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db"
    else
      echo "✗ Signing failed (see above)"
    fi
    exit 1
  fi
}
sign "$APP/Contents/Resources/MediaBridge.dylib"
sign --identifier local.sabir.ledge "$APP"
echo "✓ Built $APP"
