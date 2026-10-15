#!/bin/bash
# Builds a notarized, stapled BassJump.app for public download and zips it.
#
# One-time setup (needs a paid Apple Developer membership, Account Holder/Admin role):
#   1. Xcode → Settings → Accounts → KSQ Studios LLC → Manage Certificates → + →
#      "Developer ID Application".
#   2. Store notarization credentials in the keychain (app-specific password from
#      appleid.apple.com):
#        xcrun notarytool store-credentials BassJumpNotary \
#          --apple-id you@example.com --team-id BWZWZZ6FB7 --password abcd-efgh-ijkl-mnop
#
# Usage: scripts/release.sh            → build/BassJump-<version>.zip (notarized)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | grep 'Developer ID Application' | grep 'BWZWZZ6FB7' | head -1 | awk '{print $2}')
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate for team BWZWZZ6FB7 — see setup above."; exit 1; }
PROFILE="${NOTARY_PROFILE:-BassJumpNotary}"

xcodegen generate --quiet
xcodebuild -project BassJump.xcodeproj -scheme BassJump -configuration Release -destination "generic/platform=macOS" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build/DD-release \
  CODE_SIGN_IDENTITY="$IDENTITY" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build

APP=build/release/BassJump.app
rm -rf build/release && mkdir -p build/release
cp -R build/DD-release/Build/Products/Release/BassJump.app "$APP"
scripts/sign-sparkle.sh "$APP" "$IDENTITY" --timestamp
codesign --verify --deep --strict "$APP"
# Notarization rejects debug entitlements; make sure none slipped in.
if codesign -d --entitlements - "$APP" "$APP/Contents/PlugIns/BassJumpControls.appex" 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow present — refusing to submit"; exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/BassJump-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple for notarization…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute -vv "$APP"

# Sparkle update feed: sign the zip with the EdDSA key in the login keychain and add it
# to appcast.xml. Commit appcast.xml after uploading the zip to the GitHub release.
SPARKLE_BIN=build/DD-release/SourcePackages/artifacts/sparkle/Sparkle/bin
SIG=$("$SPARKLE_BIN/sign_update" --account BassJumpRevived -p "$ZIP")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")
scripts/appcast.py "$VERSION" "$BUILD" "$ZIP" "$SIG" "$MINOS"
echo "Ready to publish: $ZIP (tag v$VERSION), then commit appcast.xml"
