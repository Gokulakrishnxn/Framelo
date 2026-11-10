#!/bin/bash
# Checks that an app bundle is well-formed: plist, usage strings, executable, icon and signature.
set -euo pipefail
APP="${1:-build/Framelo.app}"
fail() { echo "✗ $1" >&2; exit 1; }

plutil -lint -s "$APP/Contents/Info.plist" || fail "Info.plist is not valid"
for key in CFBundleIdentifier NSMicrophoneUsageDescription NSCameraUsageDescription NSSpeechRecognitionUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 || fail "Info.plist is missing $key"
done
[ -x "$APP/Contents/MacOS/Framelo" ] || fail "executable missing"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "icon missing"
codesign --verify --strict "$APP" 2>/dev/null || fail "code signature does not verify"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "audio-input" || fail "entitlements missing"
echo "✓ Bundle checks passed"
