#!/bin/bash
# Builds build/Wired In.app from the Swift package.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copy to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="com.pberry.WiredIn"
APP="build/Wired In.app"

swift build -c release --product WiredIn
swift build -c release --product wired
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WiredIn" "$APP/Contents/MacOS/Wired In"
cp "$BIN/wired" "$APP/Contents/MacOS/wired"

# Reuse the original icon if the old app is sitting next to us.
if [[ -f "Wired In.app/Contents/Resources/AppIcon.icns" ]]; then
  cp "Wired In.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Wired In</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Wired In</string>
  <key>CFBundleDisplayName</key><string>Wired In</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Wired In uses Bluetooth to find and control Bluetooth Wired In signs.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>CFBundleURLSchemes</key><array><string>wiredin</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so launch-at-login works locally.
codesign --force --sign - "$APP/Contents/MacOS/wired"
codesign --force --sign - "$APP"

echo "Built $APP (version $VERSION build $BUILD)"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Wired In.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Wired In.app"
fi
