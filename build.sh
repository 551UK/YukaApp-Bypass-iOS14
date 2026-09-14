#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build packages
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"

# Recovery build: use the launch-stable core only. The experimental helper
# source may remain in the repository, but it is deliberately not compiled.
sed \
 -e 's/Tweak 1\.0\.6 loaded/Tweak 1.0.9 loaded/g' \
 -e 's/Yuka 1\.0\.6 • Info/Yuka 1.0.9 • Info/g' \
 YukaBypass.m > build/YukaBypass.build.m

xcrun --sdk iphoneos clang -isysroot "$sdk_path" \
 -arch arm64 -arch arm64e -miphoneos-version-min=14.0 \
 -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -I . -framework Foundation -framework UIKit \
 -install_name /Library/MobileSubstrate/DynamicLibraries/YukaBypass.dylib \
 build/YukaBypass.build.m -o build/YukaBypass.dylib
codesign --force --sign - --timestamp=none build/YukaBypass.dylib
codesign --verify --strict build/YukaBypass.dylib
xcrun lipo build/YukaBypass.dylib -verify_arch arm64 arm64e
python3 package.py
