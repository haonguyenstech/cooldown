#!/bin/bash
# Build and install Cooldown.app into ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Cooldown"
BUNDLE="$HOME/Applications/$APP_NAME.app"

mkdir -p build "$HOME/Applications"

echo "Compiling (universal: arm64 + x86_64)…"
for ARCH in arm64 x86_64; do
  swiftc -O \
    -target "$ARCH-apple-macos13.0" \
    Sources/main.swift \
    -o "build/Cooldown-$ARCH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine
done
lipo -create -output build/Cooldown build/Cooldown-arm64 build/Cooldown-x86_64

echo "Bundling…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp build/Cooldown "$BUNDLE/Contents/MacOS/Cooldown"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "Signing (ad-hoc)…"
codesign --force --sign - "$BUNDLE"

echo "Done: $BUNDLE"
echo "Launch: open \"$BUNDLE\""
