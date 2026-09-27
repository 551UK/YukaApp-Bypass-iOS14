#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build packages
mkdir -p build packages
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -isysroot "$sdk_path" \
 -arch arm64 -arch arm64e -miphoneos-version-min=12.0 \
 -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra \
 -Wno-deprecated-declarations -Wno-cast-of-sel-type -Wno-incompatible-pointer-types \
 -framework Foundation -framework AVFoundation -framework UIKit \
 -install_name /Library/MobileSubstrate/DynamicLibraries/YTPlaybackDiagFix.dylib \
 YTPlaybackDiagFix.m -o build/YTPlaybackDiagFix.dylib
codesign --force --sign - --timestamp=none build/YTPlaybackDiagFix.dylib
codesign --verify --strict build/YTPlaybackDiagFix.dylib
xcrun lipo build/YTPlaybackDiagFix.dylib -verify_arch arm64 arm64e
python3 package.py
