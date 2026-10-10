#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Building RippleShare.app requires macOS and Xcode command line tools.' >&2
  exit 1
fi
swift test
swift build -c release --arch arm64
swift build -c release --arch x86_64
app="dist/RippleShare.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/RippleShare .build/x86_64-apple-macosx/release/RippleShare -output "$app/Contents/MacOS/RippleShare"
cp -R .build/arm64-apple-macosx/release/RippleShare_RippleCore.bundle "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift dist
iconutil -c icns dist/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" dist/RippleShare-0.1.0-macOS-universal.zip
shasum -a 256 dist/RippleShare-0.1.0-macOS-universal.zip > dist/SHA256SUMS.txt
echo "Built $app (Apple Silicon + Intel, ad-hoc signed developer preview)"
