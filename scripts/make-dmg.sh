#!/bin/bash
# Wraps a notarized BassJump.app in a drag-to-Applications disk image, then signs,
# notarizes and staples the image itself (so it opens without warnings when downloaded).
# Usage: scripts/make-dmg.sh <BassJump.app> <out.dmg> <signing identity> [notary profile]
set -euo pipefail
APP="$1"; OUT="$2"; ID="$3"; PROFILE="${4:-BassJumpNotary}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/BassJump.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -quiet -volname "BassJump Revived" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
codesign --force --sign "$ID" --timestamp "$OUT"
echo "Notarizing $(basename "$OUT")…"
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"
spctl --assess --type open --context context:primary-signature -vv "$OUT"
