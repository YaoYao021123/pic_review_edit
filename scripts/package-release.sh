#!/bin/bash
# Builds the app and packs it as dist/Lucet-<version>-arm64.zip for a GitHub Release.
# The app is ad-hoc signed only (no Apple Developer ID yet), so macOS asks users to allow it once
# in System Settings › Privacy & Security — the website's FAQ explains the steps.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bash scripts/run-workbench.sh --build-only
built=".build/MediaWorkbench.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")"
# Ship it under its real name, so Finder and the Applications folder show Lucet 光集.
rm -rf dist; mkdir -p dist
app="dist/Lucet 光集.app"
ditto "$built" "$app"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
zip="dist/Lucet-${version}-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
shasum -a 256 "$zip"
