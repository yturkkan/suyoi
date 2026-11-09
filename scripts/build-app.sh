#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/swift-local.sh build -c release
BIN_DIR="$(./scripts/swift-local.sh build -c release --show-bin-path)"
APP="$PWD/build/Suyoi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Suyoi" "$APP/Contents/MacOS/Suyoi"
/usr/bin/strip -x "$APP/Contents/MacOS/Suyoi"
if [ -f "$PWD/Resources/AppIcon.icns" ]; then
    cp "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Suyoi</string>
<key>CFBundleDisplayName</key><string>Suyoi</string>
<key>CFBundleIdentifier</key><string>local.suyoi.app</string>
<key>CFBundleExecutable</key><string>Suyoi</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.3</string>
<key>CFBundleVersion</key><string>0.3.3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Y. Türkkan (@yturkkan)</string>
<key>NSAppleEventsUsageDescription</key><string>Suyoi uses Apple Events to send explicit user-submitted steering commands to matching Terminal or iTerm2 tabs.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
touch "$APP"
rm -f "$PWD/build/Suyoi.app.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/build/Suyoi.app.zip"
(cd "$PWD/build" && /usr/bin/shasum -a 256 Suyoi.app.zip > Suyoi.app.zip.sha256)
printf '\nBuilt locally: %s\nPackaged archive: %s\nLaunch manually: open "%s"\n' "$APP" "$PWD/build/Suyoi.app.zip" "$APP"
