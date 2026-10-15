#!/bin/bash
# Builds BassJump.app (Apple Silicon) into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/BassJumpRevived"
APP="build/BassJump.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BassJump"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Icon Composer icon → Assets.car (Liquid Glass) + AppIcon.icns (older macOS)
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.2 --app-icon AppIcon \
  --output-partial-info-plist build/icon-partial.plist >/dev/null
codesign --force --sign - "$APP"
echo "Built $APP"
