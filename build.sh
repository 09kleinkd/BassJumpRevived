#!/bin/bash
# Builds BassJump.app (universal: Apple Silicon + Intel) with Xcode into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications, and relaunch
# Requires Xcode and XcodeGen (brew install xcodegen). Override signing with SIGN_IDENTITY=...
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

# Prefer the team's Developer ID (same signature as public releases, so macOS keeps the
# audio permissions across local rebuilds); fall back to Apple Development.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | grep 'BWZWZZ6FB7' | head -1 | awk '{print $2}')}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Apple Development' | grep -v REVOKED | grep 'ZSV7558J3F' | head -1 | awk '{print $2}')}"
[ -n "$IDENTITY" ] || { echo "No Apple Development signing identity found"; exit 1; }

xcodebuild -project BassJump.xcodeproj -scheme BassJump -configuration Release -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build/DD CODE_SIGN_IDENTITY="$IDENTITY" ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build
rm -rf build/BassJump.app
cp -R build/DD/Build/Products/Release/BassJump.app build/BassJump.app
scripts/sign-sparkle.sh build/BassJump.app "$IDENTITY"
echo "Built build/BassJump.app (signed: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/BassJump.app"
  pkill -x BassJump 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R build/BassJump.app "$DEST"
  # Register the Control Center extension right away.
  pluginkit -a "$DEST/Contents/PlugIns/BassJumpControls.appex" 2>/dev/null || true
  open "$DEST"
  echo "Installed and launched $DEST"
fi
