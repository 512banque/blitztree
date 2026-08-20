#!/bin/zsh
# Build BlitzTree.app: Rust engine + Swift UI, assembled into a bundle.
set -euo pipefail
cd "$(dirname "$0")"
source "$HOME/.cargo/env"

echo "==> Rust engine"
cargo build --release

APP=build/BlitzTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Swift UI"
swiftc app/*.swift \
    -import-objc-header app/bz.h \
    -O -parse-as-library \
    -target arm64-apple-macos15.0 \
    -L target/release -lblitztree \
    -framework AppKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/BlitzTree"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BlitzTree</string>
    <key>CFBundleDisplayName</key><string>BlitzTree</string>
    <key>CFBundleIdentifier</key><string>dev.ahmed.blitztree</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>BlitzTree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Ahmed Khaleel</string>
</dict>
</plist>
EOF
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a real identity: stable code requirement -> TCC/FDA grants survive rebuilds.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "==> Built $APP"
