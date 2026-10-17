#!/bin/bash
# Fast debug build of the workbench executable for local iteration.
# Prints the binary path. Release packaging stays in run-workbench.sh.
set -euo pipefail
workbench_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workbench_root"
export CLANG_MODULE_CACHE_PATH="$workbench_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$workbench_root/.build/swift-module-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(--disable-sandbox --build-system native --sdk "$sdk" --configuration debug
       --scratch-path .build/native-debug --cache-path .build/cache --config-path .build/config --security-path .build/security)
swift build "${flags[@]}" --product media-workbench >&2
bin_dir="$(swift build "${flags[@]}" --show-bin-path)"
# An unbundled executable looks up *.lproj next to itself. Run it with
# `-AppleLanguages '(en)'` to see the English interface.
for lproj in Localization/*.lproj; do rm -rf "$bin_dir/$(basename "$lproj")"; cp -R "$lproj" "$bin_dir/"; done
cp assets/models/adaptive-lut.bin "$bin_dir/"
echo "$bin_dir/media-workbench"
