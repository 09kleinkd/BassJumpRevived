#!/bin/bash
# Builds BassJump.app (Apple Silicon) into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications, and relaunch
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

# Sign with a stable identity when one exists, so macOS keeps the audio-recording
# permission across rebuilds. Override with SIGN_IDENTITY=... ; falls back to ad-hoc.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Apple Development' | grep -v REVOKED | head -1 | awk '{print $2}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/BassJump.app"
  pkill -x BassJump 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
