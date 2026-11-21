#!/bin/zsh
# Makes build/Ledge-<version>.dmg for GitHub Releases: a release build (signed ad hoc, no
# personal paths, updates from Releases) with an Applications shortcut to drag it onto.
# Usage: scripts/package.sh   then: gh release upload v<version> build/Ledge-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && echo "  (note: uncommitted changes are included in this build)"

LEDGE_RELEASE=1 scripts/build.sh

echo "• Making the disk image"
STAGE=build/dmg
DMG="build/Ledge-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Ledge.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ledge $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" 2>&1 \
  | grep -v "is deprecated" || true
rm -rf "$STAGE"
# Nothing from this Mac's folders should be inside.
if LC_ALL=C grep -rqa "$HOME" build/Ledge.app; then
  echo "✗ build/Ledge.app contains paths from this Mac ($HOME); not packaging it"
  rm -f "$DMG"
  exit 1
fi
echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
