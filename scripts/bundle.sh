#!/bin/zsh
# Builds Terminaly.app into ./build
#   VERSION file      → CFBundleShortVersionString
#   git commit count  → CFBundleVersion (monotonic; Sparkle compares this)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
FEED_URL="https://github.com/drarekx/terminaly/releases/latest/download/appcast.xml"
SU_PUBLIC_KEY="W4VvjKE5SOTxfNFUIxGA+FJrAD24d4rZ0eWhgOm8X1Q="

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/Terminaly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Terminaly" "$APP/Contents/MacOS/Terminaly"
cp "$BIN_DIR/tly" "$APP/Contents/MacOS/tly"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Terminaly</string>
  <key>CFBundleDisplayName</key><string>Terminaly</string>
  <key>CFBundleIdentifier</key><string>com.drarek.terminaly</string>
  <key>CFBundleExecutable</key><string>Terminaly</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Developer ID). Sparkle accepts identity changes when the EdDSA key matches.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/MacOS/tly"
codesign --force --sign - "$APP"
echo "Built $APP $VERSION ($BUILD)"
