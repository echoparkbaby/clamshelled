#!/bin/bash
# Builds Clamshelled.app (a menu-bar / LSUIElement app) from the SwiftPM binary.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Clamshelled.app"
BUNDLE_ID="com.brandon.clamshelled"
HELPER_ID="com.brandon.clamshelled.helper"   # pinned by the XPC requirement
# Apple requires CFBundleShortVersionString to be numeric, period-separated —
# non-numeric labels (e.g. "1.0RC1") are not. Keep the plist legal and carry any
# display label in a separate key (shown in the menu) and in the DMG filename.
VERSION="1.0.0"          # CFBundleShortVersionString (must stay numeric)
VERSION_DISPLAY="1.0.0"  # what the menu shows
DMG_SUFFIX="1.0.0"       # what the DMG file is called
BUILD="2"                # CFBundleVersion — monotonic build number (integer)
# Signing identity. If SIGN_ID isn't provided, auto-detect a "Developer ID
# Application" identity from the keychain — by its unique SHA-1 hash, so
# duplicate certs with the same name don't cause an "ambiguous" error.
# Falls back to ad-hoc only if no Developer ID identity exists.
TEAM_ID="AQ5XNNSVN7"   # pinned in the XPC requirements — identity MUST match
if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning \
        | awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) {print $2; exit}')"
fi
[ -z "$SIGN_ID" ] && SIGN_ID="-"
# Auto-selecting a different team's identity would build an app whose halves can't
# talk to each other. Fail loudly instead.
if [ "$SIGN_ID" != "-" ] && ! security find-identity -v -p codesigning \
        | grep -q "$SIGN_ID.*($TEAM_ID)"; then
    echo "✖ signing identity $SIGN_ID is not team $TEAM_ID — XPC pinning would break" >&2
    exit 1
fi

echo "▸ Building release binary (universal: arm64 + x86_64)…"
# Universal so it runs on Intel Macs too, not just Apple silicon.
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/clamshelled"

echo "▸ Building app icon from Assets.xcassets…"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ROOT/build"
cp -R "$ROOT/Sources/clamshelled/Resources/Assets.xcassets/AppIcon.appiconset" "$ICONSET"
rm "$ICONSET/Contents.json"
iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/clamshelled"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Privileged helper: the root LaunchDaemon plus its launchd plist. SMAppService
# requires the plist at Contents/Library/LaunchDaemons/ and resolves BundleProgram
# relative to the app bundle.
HELPER_BIN="$(dirname "$BIN")/ClamshelledHelper"
if [ ! -x "$HELPER_BIN" ]; then
    echo "✖ helper binary not built: $HELPER_BIN" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$HELPER_BIN" "$APP/Contents/MacOS/ClamshelledHelper"
cp "$ROOT/helper/com.brandon.clamshelled.helper.plist" \
   "$APP/Contents/Library/LaunchDaemons/com.brandon.clamshelled.helper.plist"
RESOURCE_BUNDLE="$(find "$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)" -maxdepth 1 -type d -name 'clamshelled_*.bundle' -print -quit)"
# Icons are NOT optional: a missing menu-bar asset ships an invisible menulet.
if [ -z "$RESOURCE_BUNDLE" ]; then
    echo "✖ resource bundle not found — refusing to ship without menu-bar icons" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
for icon in clamshell-open-template-36 clamshell-closed-template-36; do
    if ! find "$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")" -name "$icon.png" | grep -q .; then
        echo "✖ missing menu-bar icon: $icon.png" >&2
        exit 1
    fi
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Clamshelled</string>
    <key>CFBundleDisplayName</key>     <string>Clamshelled</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>clamshelled</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>ClamshelledDisplayVersion</key><string>${VERSION_DISPLAY}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Brandon Walter</string>
</dict>
</plist>
PLIST

# Sign inner-to-outer. NOT --deep: it would re-sign the helper and derive its
# identifier from the filename ("ClamshelledHelper"), breaking the XPC code-signing
# requirement, which pins "com.brandon.clamshelled.helper".
if [ "$SIGN_ID" = "-" ]; then
    echo "▸ WARNING: no Developer ID found — ad-hoc signing (XPC pinning will FAIL)…"
    CS=(--force --sign -)
else
    echo "▸ Signing with: $SIGN_ID"
    CS=(--force --options runtime --timestamp --sign "$SIGN_ID")
fi

NESTED="$APP/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"
[ -d "$NESTED" ] && codesign "${CS[@]}" "$NESTED"
codesign "${CS[@]}" -i "$HELPER_ID" "$APP/Contents/MacOS/ClamshelledHelper"
codesign "${CS[@]}" -i "$BUNDLE_ID" "$APP"

echo "▸ Verifying…"
codesign --verify --deep --strict --verbose=2 "$APP"

# The XPC layer trusts these EXACT requirements. If the signing identity doesn't
# satisfy them, the app and helper silently refuse to talk to each other — so make
# that a build failure, not a runtime mystery.
if [ "$SIGN_ID" != "-" ]; then
    echo "▸ Asserting XPC code-signing requirements…"
    APP_REQ="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
    HELPER_REQ="anchor apple generic and identifier \"$HELPER_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
    if ! codesign --verify -R="$APP_REQ" "$APP" 2>/dev/null; then
        echo "✖ app does NOT satisfy the requirement the helper enforces" >&2; exit 1
    fi
    if ! codesign --verify -R="$HELPER_REQ" "$APP/Contents/MacOS/ClamshelledHelper" 2>/dev/null; then
        echo "✖ helper does NOT satisfy the requirement the app enforces" >&2; exit 1
    fi
    echo "  ✓ both directions satisfied (team $TEAM_ID)"
fi

echo "▸ Resulting signature:"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|Signature=" || true

echo "✓ Built $APP"
