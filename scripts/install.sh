#!/bin/zsh
# Builds Ledge, replaces the copy in /Applications, and opens it.
# Usage: scripts/install.sh   (run it again any time to update)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

echo "• Installing to /Applications"
pkill -x Ledge 2>/dev/null && sleep 0.5 || true
rm -rf /Applications/Ledge.app
cp -R build/Ledge.app /Applications/Ledge.app

open /Applications/Ledge.app
echo "✓ Ledge is running. Right-click the notch for settings."
