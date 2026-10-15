#!/bin/bash
# Re-signs Sparkle's embedded helpers with our identity (notarization requires every
# executable to carry the Developer ID, a secure timestamp and the hardened runtime),
# then re-seals the app. BassJump isn't sandboxed, so Sparkle's XPC services aren't needed.
# Usage: scripts/sign-sparkle.sh <BassJump.app> <identity> [--timestamp]
set -euo pipefail
APP="$1"; ID="$2"; TS="${3:-}"
FW="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FW" ] || exit 0
ENT="$(dirname "$0")/../Resources/BassJump-Release.entitlements"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
codesign -f -s "$ID" -o runtime $TS "$FW/Versions/B/Autoupdate"
codesign -f -s "$ID" -o runtime $TS "$FW/Versions/B/Updater.app"
codesign -f -s "$ID" -o runtime $TS "$FW"
codesign -f -s "$ID" -o runtime $TS --entitlements "$ENT" "$APP"
