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

# Notarize when the app carries a Developer ID signature and notary
# credentials are stored (one-time: `xcrun notarytool store-credentials
# blitztree-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>`).
if codesign -dv build/BlitzTree.app 2>&1 | grep -q "Authority=Developer ID Application"; then
    DEVID=$(codesign -dv build/BlitzTree.app 2>&1 | awk -F= '/^Authority=Developer ID Application/{print $2; exit}')
    codesign --force --timestamp --sign "$DEVID" BlitzTree.dmg
    xcrun notarytool submit BlitzTree.dmg --keychain-profile blitztree-notary --wait
    xcrun stapler staple BlitzTree.dmg
    NOTES="Download BlitzTree.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch."
else
    NOTES="Download BlitzTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
fi

gh release create "v$V" BlitzTree.dmg \
    --title "BlitzTree $V" \
    --notes "$NOTES"
echo "==> released v$V"
