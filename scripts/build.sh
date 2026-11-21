#!/bin/zsh
# Builds build/Ledge.app from source. Usage: scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Ledge.app
mkdir -p build

# Ledge needs Xcode: SwiftUI's macros (like @State) run a plugin that comes with Xcode, not
# with the Command Line Tools. If macOS points at the Command Line Tools but Xcode is installed,
# use Xcode for this build (nothing on the system changes).
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$XCODE" ]]; then
    echo "• Using $XCODE (macOS is set to the Command Line Tools, which can't build SwiftUI apps)"
    export DEVELOPER_DIR="$XCODE/Contents/Developer"
  fi
fi

echo "• Compiling Ledge"
FLAGS=(-c release --arch arm64)
# LEDGE_BUILD_SYSTEM=native uses Swift's older build engine (see "Could not initialize build system" below).
[[ -n "${LEDGE_BUILD_SYSTEM:-}" ]] && FLAGS+=(--build-system "$LEDGE_BUILD_SYSTEM")

# Builds, keeping the full output in build/swift-build.log and showing a progress counter
# ([42/96]) on one line, so a long first build never looks stuck.
compile() {
  swift build "${FLAGS[@]}" 2>&1 | tee build/swift-build.log | awk '
    /^\[[0-9]+[^]]*[0-9]+\]/ { match($0, /^\[[^]]*\]/); printf "\r  %s ", substr($0, RSTART, RLENGTH); fflush() }
    END { printf "\r                    \r"; fflush() }'
  return ${pipestatus[1]}
}

failed() {
  if grep -q "SwiftUIMacros" build/swift-build.log; then
    echo "✗ This Mac can't build SwiftUI apps yet: it has the Command Line Tools but not Xcode."
    echo "  Install Xcode (free) from the App Store, open it once, then run this again."
    echo "  (If Xcode is somewhere other than /Applications, run: sudo xcode-select -s /path/to/Xcode.app)"
    exit 1
  fi
  grep -E "error" build/swift-build.log | head -20
  echo "✗ Build failed (see build/swift-build.log)"
  exit 1
}
# Stop here if the build fails, so an old copy is never installed by mistake.
if ! compile; then
  # Swift Build (the default engine) can fail to start on a Mac whose Xcode or Command Line
  # Tools aren't fully set up ("Unknown error parsing property list"). The older engine
  # usually still works, so try it once.
  if [[ -z "${LEDGE_BUILD_SYSTEM:-}" ]] && grep -q "Could not initialize build system" build/swift-build.log; then
    echo "  (Swift Build couldn't start on this Mac; trying Swift's older build engine)"
    FLAGS+=(--build-system native)
    compile || failed
  else
    failed
  fi
fi
grep -E "warning: " build/swift-build.log | grep -v "build-system native' has been deprecated" | head -10 || true
BIN="$(swift build "${FLAGS[@]}" --show-bin-path 2>/dev/null)/Ledge"

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
# And where the source is, so "Check for updates" finds it wherever the project was cloned.
/usr/libexec/PlistBuddy -c "Add :LedgeSource string $PWD" "$APP/Contents/Info.plist"
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
