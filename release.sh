#!/bin/zsh
# Build, package as dmg, and publish a GitHub release.
# Usage: ./release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 0.1.0}"

./build.sh
STAGE=$(mktemp -d)
cp -R build/BlitzTree.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "BlitzTree.dmg"
hdiutil create -volname BlitzTree -srcfolder "$STAGE" -ov -format UDZO -quiet BlitzTree.dmg
rm -rf "$STAGE"

gh release create "v$V" BlitzTree.dmg \
    --title "BlitzTree $V" \
    --notes "Download BlitzTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
echo "==> released v$V"
