#!/bin/bash
# Runs the same build validation used by continuous integration.
set -euo pipefail
cd "$(dirname "$0")"

echo "› Checking shell scripts…"
bash -n build.sh notarize.sh check.sh

echo "› Checking app metadata…"
plutil -lint Info.plist

echo "› Building with strict Swift concurrency checks…"
./build.sh

echo "› Validating bundle and executable…"
plutil -lint DiskTree.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 DiskTree.app
file DiskTree.app/Contents/MacOS/DiskTree

echo "✓ All checks passed"
