#!/bin/bash
# Builds DiskTree.app — a self-contained macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="DiskTree.app"
BIN="DiskTree"
CONTENTS="$APP/Contents"
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/disktree-build.XXXXXX")"
trap 'rm -rf "$BUILD_TMP"' EXIT

ARCHS_VALUE="${DISKTREE_ARCHS:-arm64 x86_64}"
read -r -a BUILD_ARCHS <<< "$ARCHS_VALUE"
if [ "${#BUILD_ARCHS[@]}" -eq 0 ]; then
    echo "✗ DISKTREE_ARCHS must contain at least one architecture."
    exit 1
fi

echo "› Compiling Swift sources…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

for ARCH in "${BUILD_ARCHS[@]}"; do
    case "$ARCH" in
        arm64|x86_64) ;;
        *)
            echo "✗ Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    echo "  • $ARCH"
    swiftc -O -parse-as-library \
        -swift-version 6 \
        -strict-concurrency=complete -warnings-as-errors \
        -target "$ARCH-apple-macos14.0" \
        -framework SwiftUI -framework AppKit -framework Combine \
        Sources/*.swift \
        -o "$BUILD_TMP/$BIN-$ARCH"
done

if [ "${#BUILD_ARCHS[@]}" -eq 1 ]; then
    cp "$BUILD_TMP/$BIN-${BUILD_ARCHS[0]}" "$CONTENTS/MacOS/$BIN"
else
    lipo -create "${BUILD_ARCHS[@]/#/$BUILD_TMP/$BIN-}" -output "$CONTENTS/MacOS/$BIN"
fi

cp Info.plist "$CONTENTS/Info.plist"

# Stamp the build date so the app can show which build is running.
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
plutil -replace BuildDate -string "$BUILD_DATE" "$CONTENTS/Info.plist"
echo "› Build date: $BUILD_DATE"

# App icon (optional — skip gracefully if absent).
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

# Sign with a stable identity if one exists, so macOS (TCC) remembers grants
# like Full Disk Access across rebuilds. Falls back to ad-hoc otherwise.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' \
    | head -1 | tr -d '"' || true)"

if [ -n "$IDENTITY" ]; then
    echo "› Code signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "› No stable identity found — ad-hoc signing (FDA grant won't persist across rebuilds)…"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "✓ Built $APP"

# Installation is opt-in so a normal build never modifies /Applications.
# Set DISKTREE_INSTALL=1 when you want to replace the installed development copy.
if [ "${DISKTREE_INSTALL:-0}" = "1" ]; then
    DEST="/Applications/$APP"
    # Quit a running installed copy so the bundle can be replaced cleanly.
    pkill -f "$DEST/Contents/MacOS/$BIN" 2>/dev/null || true
    if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
        echo "✓ Installed to $DEST"
    else
        echo "⚠︎ Couldn't update $DEST (permission?). Copy it manually if needed."
    fi
fi

echo "  Run it with:  open $APP"
echo "  Install it with:  DISKTREE_INSTALL=1 ./build.sh"
