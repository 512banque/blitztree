#!/bin/zsh
# Build, notarize, package as dmg, and publish a GitHub release.
# Usage: ./release.sh 0.1.0 [notes.md]
set -euo pipefail
cd "$(dirname "$0")"
V="${1:?version, e.g. 0.1.0}"
NOTES_FILE="${2:-}"

./build.sh

# Notarize when the app carries a Developer ID signature and notary
# credentials are stored (one-time: `xcrun notarytool store-credentials
# blitztree-notary --key <AuthKey.p8> --key-id <id> --issuer <uuid>`).
# The app is stapled before packaging so it opens offline once copied out
# of the dmg; the dmg is then signed, notarized and stapled itself.
NOTARIZE=0
if codesign -dv build/BlitzTree.app 2>&1 | grep -q "Authority=Developer ID Application"; then
    NOTARIZE=1
    DEVID=$(codesign -dv build/BlitzTree.app 2>&1 | awk -F= '/^Authority=Developer ID Application/{print $2; exit}')
    echo "==> Notarizing app"
    ZIP=$(mktemp -d)/BlitzTree.zip
    ditto -c -k --keepParent build/BlitzTree.app "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile blitztree-notary --wait
    xcrun stapler staple build/BlitzTree.app
    rm -f "$ZIP"
fi

STAGE=$(mktemp -d)
cp -R build/BlitzTree.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "BlitzTree.dmg"
hdiutil create -volname BlitzTree -srcfolder "$STAGE" -ov -format UDZO -quiet BlitzTree.dmg
rm -rf "$STAGE"

if (( NOTARIZE )); then
    echo "==> Notarizing dmg"
    codesign --force --timestamp --sign "$DEVID" BlitzTree.dmg
    xcrun notarytool submit BlitzTree.dmg --keychain-profile blitztree-notary --wait
    xcrun stapler staple BlitzTree.dmg
    spctl --assess --type open --context context:primary-signature -v BlitzTree.dmg
    NOTES="Download BlitzTree.dmg and drag it to Applications, then grant Full Disk Access when asked and relaunch."
else
    NOTES="Download BlitzTree.dmg, drag to Applications. First launch: System Settings → Privacy & Security → Open Anyway (unnotarized build), then grant Full Disk Access and relaunch."
fi
[[ -n "$NOTES_FILE" ]] && NOTES=$(<"$NOTES_FILE")

shasum -a 256 BlitzTree.dmg > SHA256SUMS.txt
gh release create "v$V" BlitzTree.dmg SHA256SUMS.txt \
    --title "BlitzTree $V" \
    --notes "$NOTES"
rm -f SHA256SUMS.txt
echo "==> released v$V"
