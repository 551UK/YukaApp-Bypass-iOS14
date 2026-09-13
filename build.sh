#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build packages
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"

# Keep the stable 1.0.6 core source intact and stamp the package-facing diagnostic
# version in a temporary build copy. The Firebase getter fix is isolated in
# YukaFirebaseKeyGetter.m so it can be removed independently if device testing fails.
sed \
 -e 's/Tweak 1\.0\.6 loaded/Tweak 1.0.8 loaded/g' \
 -e 's/Yuka 1\.0\.6 • Info/Yuka 1.0.8 • Info/g' \
 -e 's/Request-only update/Request update + Firebase API-key getter/g' \
 YukaBypass.m > build/YukaBypass.build.m

xcrun --sdk iphoneos clang -isysroot "$sdk_path" \
 -arch arm64 -arch arm64e -miphoneos-version-min=14.0 \
 -dynamiclib -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -I . -framework Foundation -framework UIKit \
 -install_name /Library/MobileSubstrate/DynamicLibraries/YukaBypass.dylib \
 build/YukaBypass.build.m YukaFirebaseKeyGetter.m -o build/YukaBypass.dylib
codesign --force --sign - --timestamp=none build/YukaBypass.dylib
codesign --verify --strict build/YukaBypass.dylib
xcrun lipo build/YukaBypass.dylib -verify_arch arm64 arm64e
python3 package.py
