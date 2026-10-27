"""Shared Finder layout for preview and signed Verbemo images."""
format = 'UDZO'
files = [(defines['app'], 'Verbemo.app')]
symlinks = {'Applications': '/Applications'}
icon = defines['icon']
background = defines['background']
window_rect = ((200, 160), (660, 420))
icon_locations = {'Verbemo.app': (170, 210), 'Applications': (490, 210)}
icon_size = 96
text_size = 13
default_view = 'icon-view'
show_icon_preview = True
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
