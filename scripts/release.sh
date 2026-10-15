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
xcodebuild -project BassJump.xcodeproj -scheme BassJump -configuration Release \
  -derivedDataPath build/DD-release \
  CODE_SIGN_IDENTITY="$IDENTITY" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_ENTITLEMENTS="Resources/BassJump-Release.entitlements" -quiet build

APP=build/release/BassJump.app
rm -rf build/release && mkdir -p build/release
cp -R build/DD-release/Build/Products/Release/BassJump.app "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="build/BassJump-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple for notarization…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute -vv "$APP"
echo "Ready to publish: $ZIP"
