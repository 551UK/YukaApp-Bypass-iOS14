#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build packages
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"

xcrun --sdk iphoneos clang -isysroot "$sdk_path" \
 -arch arm64 -arch arm64e -miphoneos-version-min=14.0 \
 -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror \
 -Wno-incompatible-function-pointer-types -Wno-compare-distinct-pointer-types -I . \
 -framework Foundation -framework UIKit \
 -install_name /Library/MobileSubstrate/DynamicLibraries/YukaBypass.dylib \
 YukaRepair.m YukaGRPCCompat.m YukaGRPCCompat.S -o build/YukaBypass.dylib

codesign --force --sign - --timestamp=none build/YukaBypass.dylib
codesign --verify --strict build/YukaBypass.dylib
xcrun lipo build/YukaBypass.dylib -verify_arch arm64 arm64e
python3 package.py
