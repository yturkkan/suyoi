#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PARALLEL="${SUYOI_PARALLEL:-0}"
for arg in "$@"; do
    case "$arg" in
        --parallel)
            PARALLEL=1
            ;;
        *)
            printf 'Unknown option: %s\nUsage: %s [--parallel]\n' "$arg" "$0" >&2
            exit 2
            ;;
    esac
done

if [ "$PARALLEL" = "1" ]; then
    APP_NAME="Suyoi Next"
    BUNDLE_ID="local.suyoi.next"
    SHORT_VERSION="${SUYOI_VERSION:-0.6.0-next.1}"
    BUNDLE_VERSION="${SUYOI_BUILD_VERSION:-0.6.0}"
    ARCHIVE_NAME="Suyoi-Next.app.zip"
    USAGE_DESC="Suyoi Next uses Apple Events to send explicit user-submitted steering commands to matching Terminal or iTerm2 tabs."
else
    APP_NAME="Suyoi"
    BUNDLE_ID="local.suyoi.app"
    SHORT_VERSION="${SUYOI_VERSION:-0.6.0}"
    BUNDLE_VERSION="${SUYOI_BUILD_VERSION:-0.6.0}"
    ARCHIVE_NAME="Suyoi.app.zip"
    USAGE_DESC="Suyoi uses Apple Events to send explicit user-submitted steering commands to matching Terminal or iTerm2 tabs."
fi

./scripts/swift-local.sh build -c release
BIN_DIR="$(./scripts/swift-local.sh build -c release --show-bin-path)"
APP="$PWD/build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Suyoi" "$APP/Contents/MacOS/Suyoi"
/usr/bin/strip -x "$APP/Contents/MacOS/Suyoi"
if [ -f "$PWD/Resources/AppIcon.icns" ]; then
    cp "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>Suyoi</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
<key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© 2026 Y. Türkkan (@yturkkan)</string>
<key>NSAppleEventsUsageDescription</key><string>${USAGE_DESC}</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
touch "$APP"
rm -f "$PWD/build/${ARCHIVE_NAME}" "$PWD/build/${ARCHIVE_NAME}.sha256"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$PWD/build/${ARCHIVE_NAME}"
(cd "$PWD/build" && /usr/bin/shasum -a 256 "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256")
printf '\nBuilt locally: %s\nPackaged archive: %s\nLaunch manually: open "%s"\n' "$APP" "$PWD/build/${ARCHIVE_NAME}" "$APP"
