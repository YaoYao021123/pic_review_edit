#!/bin/bash
set -euo pipefail
workbench_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workbench_root"
export CLANG_MODULE_CACHE_PATH="$workbench_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$workbench_root/.build/swift-module-cache"
workbench_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
# The host already provides a sandbox; SwiftPM's nested sandbox cannot start here.
# Record the SDK actually used, independently of the macOS 15 deployment target.
# The current Swift Build engine on this CLT host records SDK 15.0 even with
# --sdk. Its native engine correctly records the selected SDK in the executable.
swift build --disable-sandbox --build-system native --sdk "$workbench_sdk_path" --configuration release -debug-info-format none --product media-workbench --scratch-path .build/native-workbench --cache-path .build/cache --config-path .build/config --security-path .build/security
workbench_bin_dir="$(swift build --disable-sandbox --build-system native --sdk "$workbench_sdk_path" --configuration release --show-bin-path --scratch-path .build/native-workbench --cache-path .build/cache --config-path .build/config --security-path .build/security)"
workbench_app="$workbench_root/.build/MediaWorkbench.app"
mkdir -p "$workbench_app/Contents/MacOS" "$workbench_app/Contents/Resources"
# Pre-generated brand assets are durable source assets, never generated during a build.
cp "$workbench_root/assets/brand/icons/AppIcon.icns" "$workbench_app/Contents/Resources/AppIcon.icns"
cp "$workbench_root/assets/brand/runtime/EmptyLibrary-dark.png" "$workbench_app/Contents/Resources/EmptyLibrary-dark.png"
# The AI Look model (Image-Adaptive-3DLUT, Apache-2.0) and its notice.
cp "$workbench_root/assets/models/adaptive-lut.bin" "$workbench_app/Contents/Resources/adaptive-lut.bin"
cp "$workbench_root/assets/models/NOTICE.md" "$workbench_app/Contents/Resources/adaptive-lut-NOTICE.md"
# Interface languages: Simplified Chinese (source text) and English (Localization/en.lproj).
for lproj in "$workbench_root"/Localization/*.lproj; do
    rm -rf "$workbench_app/Contents/Resources/$(basename "$lproj")"
    cp -R "$lproj" "$workbench_app/Contents/Resources/"
done
cp "$workbench_bin_dir/media-workbench" "$workbench_app/Contents/MacOS/media-workbench.new"
mv -f "$workbench_app/Contents/MacOS/media-workbench.new" "$workbench_app/Contents/MacOS/media-workbench"
cat > "$workbench_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>media-workbench</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleIdentifier</key><string>local.mediaworkbench.prototype</string>
<key>CFBundleName</key><string>Lucet 光集</string>
<key>CFBundleDisplayName</key><string>Lucet 光集</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>Lucet saves the photos you export into Photos, and, only when you choose Import from Photos, reads the ones you pick so you can edit them. It never changes or deletes what is already in Photos.</string>
<key>NSPhotoLibraryAddUsageDescription</key><string>Lucet saves the photos, videos and Live Photos you export into Photos. It never reads or changes the photos already there.</string>
</dict></plist>
PLIST
if [[ "${1:-}" != "--build-only" ]]; then
    open -n "$workbench_app"
fi
