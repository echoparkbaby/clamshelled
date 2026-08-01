#!/bin/bash
# Builds a laid-out DMG: background image, window size, icon positions, and a
# drag-to-Applications affordance. Called by release.sh.
#
# Uses dmgbuild, which writes the .DS_Store directly. The older AppleScript/Finder
# approach needs Automation permission and SILENTLY no-ops without it (osascript
# still exits 0), so the layout would vanish with no error.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Clamshelled.app"
VOL="Clamshelled"
DMG="${1:?usage: make-dmg.sh <output.dmg>}"
VENV="$ROOT/build/dmgvenv"
NOTE="$ROOT/build/❗️Drag Clamshelled to Applications first.txt"

[ -d "$APP" ] || { echo "✖ $APP not found" >&2; exit 1; }

# Build-time only, kept out of the app. Recreated if missing.
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "▸ Setting up DMG tooling…"
    python3 -m venv "$VENV" >/dev/null
    "$VENV/bin/pip" install --quiet dmgbuild >/dev/null
fi

echo "▸ Rendering DMG background…"
mkdir -p "$ROOT/build"
swift "$ROOT/scripts/make-dmg-background.swift" "$ROOT/build/dmg-background.png" >/dev/null

# Visible in every view mode, and readable without opening it — the styled
# background only shows in icon view.
cat > "$NOTE" <<'TXT'
Clamshelled has to be in your Applications folder before it will work.

Why: it installs a small helper to change your Mac's sleep settings, and macOS
refuses to register that helper from a disk image or a folder that can move.
Clamshelled will tell you the same thing if you try to run it from here.

  1. Drag Clamshelled to the Applications folder in this window.
  2. Open it from Applications (not from this disk image).
  3. Click the lightning-bolt menu -> Install Privileged Helper...
  4. Approve "Clamshelled" in System Settings -> General ->
     Login Items & Extensions -> Allow in the Background.

Then use "Keep Awake With Lid Closed" and shut the lid.

- Brandon Walter - github.com/EchoParkBaby
TXT

echo "▸ Building DMG…"
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -f "$DMG"
CLAMSHELLED_ROOT="$ROOT" "$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" "$VOL" "$DMG" >/dev/null

# The layout is the whole point of this script — assert it actually landed rather
# than trusting the exit code.
echo "▸ Verifying layout…"
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet
ok=1
[ -f "$MNT/.DS_Store" ] || { echo "  ✖ no .DS_Store — window layout missing" >&2; ok=0; }
# dmgbuild stores it as a hidden file at the volume root, not in a .background dir.
[ -f "$MNT/.background.png" ] || [ -f "$MNT/.background/background.png" ] \
    || { echo "  ✖ background image missing" >&2; ok=0; }
[ -e "$MNT/Applications" ] || { echo "  ✖ Applications symlink missing" >&2; ok=0; }
[ -d "$MNT/Clamshelled.app" ] || { echo "  ✖ app missing" >&2; ok=0; }
ls "$MNT" | grep -q "Drag Clamshelled" || { echo "  ✖ instruction file missing" >&2; ok=0; }
hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force >/dev/null
rmdir "$MNT" 2>/dev/null || true
[ "$ok" = 1 ] || exit 1
echo "  ✓ background, .DS_Store, symlink, app, and note all present"

echo "✓ $DMG"
