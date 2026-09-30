"""Finder layout for the BobTV drag-to-Applications disk image."""

import os


application = defines["app"]
app_name = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
background = "builtin-arrow"

window_rect = ((120, 120), (640, 300))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = True

icon_size = 112
text_size = 14
label_pos = "bottom"
icon_locations = {app_name: (145, 160), "Applications": (495, 160)}
