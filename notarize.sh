#!/bin/bash
# Produces a notarized, Gatekeeper-approved DiskTree.zip for direct distribution.
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
ZIP="DiskTree.zip"
PROFILE="${DISKTREE_NOTARY_PROFILE:-DiskTree}"
SITE_DOWNLOADS="${DISKTREE_SITE_DOWNLOADS:-}"

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
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Zip and submit to Apple; --wait blocks until Apple returns Accepted/Invalid.
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "› Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# 4. Staple the ticket into the app so it validates offline, then re-zip.
echo "› Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

# 5. Prove Gatekeeper will accept it.
echo "› Gatekeeper assessment:"
spctl -a -vvv --type execute "$APP" 2>&1 | sed 's/^/    /'

# 6. Optionally copy it to a separate website checkout.
if [ -n "$SITE_DOWNLOADS" ]; then
    mkdir -p "$SITE_DOWNLOADS"
    cp "$ZIP" "$SITE_DOWNLOADS/DiskTree.zip"
fi

echo "✓ Notarized, stapled → $ZIP"
if [ -n "$SITE_DOWNLOADS" ]; then
    echo "  Copied to $SITE_DOWNLOADS/DiskTree.zip"
fi
