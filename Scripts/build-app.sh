#!/bin/bash
# Builds Framelo.app in ./build. Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
source Scripts/toolchain.sh

echo "› Compiling ($CONFIG)…"
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --product Framelo
BIN="$(swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}" --show-bin-path)/Framelo"

APP="build/Framelo.app"
echo "› Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Framelo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
if [ ! -f build/AppIcon.icns ] || [ Scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf "$ICONSET"
  swift Scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "› Signing (ad-hoc)…"
codesign --force --sign - --entitlements Resources/Framelo.entitlements --timestamp=none "$APP"

Scripts/verify-bundle.sh "$APP"
echo "✓ Built $APP"
