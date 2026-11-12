#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'Error: Suyoi Next requires macOS 14.0 or later.\n' >&2
    exit 1
fi

REPO="yturkkan/suyoi"
ASSET_NAME="Suyoi-Next.app.zip"
SHA_NAME="Suyoi-Next.app.zip.sha256"

if [ -n "${SUYOI_TAG:-}" ]; then
    TAG="$SUYOI_TAG"
    ZIP_URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET_NAME}"
else
    printf '==> Checking latest Suyoi Next pre-release on GitHub...\n'
    RELEASES_JSON="$(/usr/bin/curl -fsSL -H "User-Agent: Suyoi-Installer" "https://api.github.com/repos/${REPO}/releases?per_page=30")"
    ZIP_URL="$(printf '%s\n' "$RELEASES_JSON" \
        | /usr/bin/grep -Eo "https://github[.]com/${REPO}/releases/download/v[0-9]+[.][0-9]+[.][0-9]+-next[.][0-9]+/${ASSET_NAME}" \
        | /usr/bin/awk -F'/download/v|-next[.]|/Suyoi-Next' '{ split($2, v, "."); printf "%06d%06d%06d%06d %s\n", v[1], v[2], v[3], $3, $0 }' \
        | /usr/bin/sort \
        | /usr/bin/tail -n 1 \
        | /usr/bin/awk '{print $2}')"
    if [ -z "$ZIP_URL" ]; then
        printf 'Error: Could not find a published Suyoi Next pre-release asset.\n' >&2
        exit 1
    fi
    TAG="$(printf '%s' "$ZIP_URL" | /usr/bin/sed -E 's|.*/download/([^/]+)/.*|\1|')"
fi

SHA_URL="https://github.com/${REPO}/releases/download/${TAG}/${SHA_NAME}"

TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/suyoi-next-install.XXXXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '==> Downloading Suyoi Next %s...\n' "$TAG"
/usr/bin/curl -fL --progress-bar "$ZIP_URL" -o "${TMP_DIR}/${ASSET_NAME}"
/usr/bin/curl -fsSL "$SHA_URL" -o "${TMP_DIR}/${SHA_NAME}"

printf '==> Verifying SHA-256 checksum...\n'
(cd "$TMP_DIR" && /usr/bin/shasum -a 256 -c "$SHA_NAME")

printf '==> Extracting and verifying app bundle...\n'
mkdir -p "${TMP_DIR}/unpack"
/usr/bin/ditto -x -k "${TMP_DIR}/${ASSET_NAME}" "${TMP_DIR}/unpack"

EXTRACTED_APP="${TMP_DIR}/unpack/Suyoi Next.app"
if [ ! -d "$EXTRACTED_APP" ]; then
    printf 'Error: Extracted archive did not contain Suyoi Next.app.\n' >&2
    exit 1
fi

/usr/bin/xattr -dr com.apple.quarantine "$EXTRACTED_APP" >/dev/null 2>&1 || true

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${EXTRACTED_APP}/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUNDLE_ID" != "local.suyoi.next" ]; then
    printf 'Error: Unexpected bundle identifier (%s).\n' "$BUNDLE_ID" >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict "$EXTRACTED_APP"

if [ -w "/Applications" ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="${HOME}/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST_APP="${DEST_DIR}/Suyoi Next.app"

if /usr/bin/pgrep -f "/Suyoi Next[.]app/Contents/MacOS/Suyoi" >/dev/null 2>&1; then
    printf '==> Closing running Suyoi Next instance...\n'
    /usr/bin/pkill -f "/Suyoi Next[.]app/Contents/MacOS/Suyoi" >/dev/null 2>&1 || true
    sleep 1
fi

printf '==> Installing to %s...\n' "$DEST_APP"
rm -rf "$DEST_APP"
mv "$EXTRACTED_APP" "$DEST_APP"
/usr/bin/xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

printf '==> Launching Suyoi Next (%s)...\n' "$TAG"
/usr/bin/open "$DEST_APP"
printf 'Done! Future updates can be installed directly inside Suyoi Next (Settings -> Check for Updates) with zero warnings.\n'
