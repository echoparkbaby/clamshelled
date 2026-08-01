#!/bin/bash
# One-shot: build → sign → dmg → notarize → staple. No searching, no prompts.
# Signing identity + notary profile come from the canonical machine config.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Clamshelled.app"
VOL="Clamshelled"

# shellcheck source=/dev/null
source ~/.config/macos-sign/.env-sign   # SIGN_ID, SIGN_HASH, TEAM_ID, NOTARY_PROFILE

echo "▸ Building + signing the app…"
SIGN_ID="$SIGN_HASH" bash "$ROOT/scripts/package.sh"   # package.sh already uses hardened runtime + timestamp

# DMG name carries the app's version — single source of truth is the built plist.
DMG_SUFFIX="$(/usr/libexec/PlistBuddy -c 'Print ClamshelledDisplayVersion' "$APP/Contents/Info.plist" 2>/dev/null | tr -d ' ' \
    || /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/Clamshelled-$DMG_SUFFIX.dmg"

echo "▸ Building signed DMG…"
bash "$ROOT/scripts/make-dmg.sh" "$DMG"
codesign --force --timestamp --sign "$SIGN_HASH" "$DMG"

echo "▸ Notarizing (profile: $NOTARY_PROFILE)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "✓ Signed + notarized: $DMG"
