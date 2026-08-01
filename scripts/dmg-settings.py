# dmgbuild settings for Clamshelled.
#
# dmgbuild writes the .DS_Store directly (via ds_store/mac_alias), so the window
# layout and background image work WITHOUT Finder automation — the AppleScript
# route silently no-ops when Terminal lacks Automation permission.
#
# Icon positions here must match the arrow drawn in make-dmg-background.swift.

import os

# dmgbuild exec()s this file, so __file__ is undefined — make-dmg.sh exports the root.
root = os.environ["CLAMSHELLED_ROOT"]
app = os.path.join(root, "Clamshelled.app")

files = [app, os.path.join(root, "build", "❗️Drag Clamshelled to Applications first.txt")]
symlinks = {"Applications": "/Applications"}

badge_icon = os.path.join(root, "build", "AppIcon.icns")
background = os.path.join(root, "build", "dmg-background.png")

# 640x400 content area, matching the background image exactly.
window_rect = ((200, 120), (640, 400))
icon_size = 96
text_size = 12

icon_locations = {
    "Clamshelled.app": (160, 180),
    "Applications": (480, 180),
    # Sits below the arrow so it never overlaps the headline or the icons.
    "❗️Drag Clamshelled to Applications first.txt": (320, 320),
}

format = "UDZO"
compression_level = 9
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
