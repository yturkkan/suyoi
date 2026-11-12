#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'Error: Suyoi requires macOS 14.0 or later.\n' >&2
    exit 1
fi

REPO="yturkkan/suyoi"
ASSET_NAME="Suyoi.app.zip"
SHA_NAME="Suyoi.app.zip.sha256"

if [ -n "${SUYOI_TAG:-}" ]; then
    TAG="$SUYOI_TAG"
else
    printf '==> Checking latest Suyoi release on GitHub...\n'
    LATEST_JSON="$(/usr/bin/curl -fsSL -H "User-Agent: Suyoi-Installer" "https://api.github.com/repos/${REPO}/releases/latest")"
    TAG="$(printf '%s\n' "$LATEST_JSON" | /usr/bin/grep -Eo '"tag_name":[[:space:]]*"v[^"]+"' | /usr/bin/head -n 1 | /usr/bin/sed -E 's/.*"([^"]+)"$/\1/')"
    if [ -z "$TAG" ]; then
        printf 'Error: Could not resolve latest Suyoi release tag from GitHub.\n' >&2
        exit 1
    fi
fi

ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"
SHA_URL="https://github.com/${REPO}/releases/download/${TAG}/${SHA_NAME}"

TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/suyoi-install.XXXXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '==> Downloading Suyoi %s...\n' "$TAG"
/usr/bin/curl -fL --progress-bar "$ZIP_URL" -o "${TMP_DIR}/${ASSET_NAME}"
/usr/bin/curl -fsSL "$SHA_URL" -o "${TMP_DIR}/${SHA_NAME}"

printf '==> Verifying SHA-256 checksum...\n'
(cd "$TMP_DIR" && /usr/bin/shasum -a 256 -c "$SHA_NAME")

printf '==> Extracting and verifying app bundle...\n'
mkdir -p "${TMP_DIR}/unpack"
/usr/bin/ditto -x -k "${TMP_DIR}/${ASSET_NAME}" "${TMP_DIR}/unpack"

EXTRACTED_APP="${TMP_DIR}/unpack/Suyoi.app"
if [ ! -d "$EXTRACTED_APP" ]; then
    printf 'Error: Extracted archive did not contain Suyoi.app.\n' >&2
    exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$EXTRACTED_APP" >/dev/null 2>&1 || true

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${EXTRACTED_APP}/Contents/Info.plist" 2>/dev/null || true)"
case "$BUNDLE_ID" in
    local.suyoi.app|io.suyoi.app) ;;
    *)
        printf 'Error: Unexpected bundle identifier (%s).\n' "$BUNDLE_ID" >&2
        exit 1
        ;;
esac

/usr/bin/codesign --verify --deep --strict "$EXTRACTED_APP"

if [ -w "/Applications" ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="${HOME}/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST_APP="${DEST_DIR}/Suyoi.app"

if /usr/bin/pgrep -f "/Suyoi[.]app/Contents/MacOS/Suyoi" >/dev/null 2>&1; then
    printf '==> Closing running Suyoi instance...\n'
    /usr/bin/pkill -f "/Suyoi[.]app/Contents/MacOS/Suyoi" >/dev/null 2>&1 || true
    sleep 1
fi

printf '==> Installing to %s...\n' "$DEST_APP"
rm -rf "$DEST_APP"
mv "$EXTRACTED_APP" "$DEST_APP"
/usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

printf '==> Launching Suyoi (%s)...\n' "$TAG"
/usr/bin/open "$DEST_APP"
printf 'Done! Future updates can be installed directly inside Suyoi (Settings -> Check for Updates) with zero warnings.\n'
