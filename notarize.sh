#!/bin/bash
# Produces a notarized, Gatekeeper-approved DiskTree.dmg for direct distribution.
#
# One-time setup (see README "Distribution"):
#   1. Create a "Developer ID Application" certificate in your Apple Developer
#      account and download/install it (double-click).
#   2. Store notarization credentials once (see README.md).
#
# Then just run:  ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="DiskTree.app"
HELPER="DiskTree.app/Contents/Helpers/DiskTreeWeeklyScan"
DMG="DiskTree.dmg"
VOLUME_NAME="DiskTree"
PROFILE="${DISKTREE_NOTARY_PROFILE:-DiskTree}"
SITE_DOWNLOADS="${DISKTREE_SITE_DOWNLOADS:-}"
DOWNLOAD_URL="${DISKTREE_DOWNLOAD_URL:-https://www.libjch.com/downloads/DiskTree.dmg}"
RELEASE_NOTES="${DISKTREE_RELEASE_NOTES:-}"
UPDATE_FEED="disktree-version.json"
DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/disktree-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING"' EXIT

# Always build fresh first.
./build.sh

# 1. Find the Developer ID Application identity (distribution cert).
IDENTITY="${DISKTREE_SIGNING_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | grep -Eo '"Developer ID Application[^"]*"' | head -1 | tr -d '"')"
fi
if [ -z "$IDENTITY" ]; then
    echo "✗ No 'Developer ID Application' certificate found in your keychain."
    echo "  Create one at: https://developer.apple.com/account/resources/certificates/add"
    echo "  (type: 'Developer ID Application'), download it, and double-click to install."
    exit 1
fi

# 2. Sign with the hardened runtime + a secure timestamp (required for notarization).
echo "› Signing: $IDENTITY (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$HELPER"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$HELPER"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Build a compressed disk image with the standard Applications shortcut.
echo "› Creating disk image…"
ditto "$APP" "$DMG_STAGING/$APP"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$DMG"

# Sign the container itself so Gatekeeper can validate its primary signature.
echo "› Signing disk image…"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

# 4. Submit the complete disk image; --wait blocks until Apple returns.
echo "› Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# 5. Staple the notarization ticket to the disk image for offline validation.
echo "› Stapling ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 6. Prove Gatekeeper will accept both the app and its distribution container.
echo "› Gatekeeper assessment:"
spctl -a -vvv --type execute "$APP" 2>&1 | sed 's/^/    /'
spctl -a -vvv --type open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/    /'

# 7. Write the update feed read by the app's "Check for Updates".
#    JSON is produced by JavaScript so notes with quotes stay valid.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
osascript -l JavaScript - "$VERSION" "$DOWNLOAD_URL" "$RELEASE_NOTES" > "$UPDATE_FEED" <<'JS'
function run(argv) {
    return JSON.stringify({ version: argv[0], url: argv[1], notes: argv[2] }, null, 2);
}
JS
plutil -lint "$UPDATE_FEED"

# 8. Optionally copy both to a separate website checkout. The DMG goes first so
#    the feed never announces a version whose download isn't there yet.
if [ -n "$SITE_DOWNLOADS" ]; then
    mkdir -p "$SITE_DOWNLOADS"
    cp "$DMG" "$SITE_DOWNLOADS/DiskTree.dmg"
    cp "$UPDATE_FEED" "$SITE_DOWNLOADS/$UPDATE_FEED"
fi

echo "✓ Notarized, stapled → $DMG (version $VERSION)"
echo "  Update feed → $UPDATE_FEED (download: $DOWNLOAD_URL)"
if [ -n "$SITE_DOWNLOADS" ]; then
    echo "  Copied both to $SITE_DOWNLOADS/ — upload the DMG before the feed."
fi
