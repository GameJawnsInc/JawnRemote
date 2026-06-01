"""
Stores the user's quick-launch app list for the phone's Apps screen.

A small JSON file the user edits from the server window ("Manage apps"). The
phone fetches it over the connection (the `getapps` request) and renders it;
tapping an entry sends the existing `launch` command. Seeded with sensible
defaults on first run.

Each entry: {"name", "target", "icon", "color"}
  target : a URL, protocol URI, or app/exe the Windows shell can open
  icon   : a keyword the app maps to an icon (see ICON_KEYWORDS)
  color  : RRGGBB hex for the icon background
"""
import json
import os

# Default location (next to this file). The GUI overrides this to the per-user
# data dir, which is writable without elevation.
APPS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apps.json")

ICON_KEYWORDS = ["play", "movie", "music", "film", "castle", "sparkle",
                 "tv", "game", "video", "web", "folder", "app", "star"]

DEFAULTS = [
    {"name": "YouTube", "target": "https://www.youtube.com", "icon": "play", "color": "FF0000"},
    {"name": "Netflix", "target": "https://www.netflix.com", "icon": "movie", "color": "E50914"},
    {"name": "Spotify", "target": "https://open.spotify.com", "icon": "music", "color": "1DB954"},
    {"name": "Prime Video", "target": "https://www.primevideo.com", "icon": "film", "color": "00A8E1"},
    {"name": "Disney+", "target": "https://www.disneyplus.com", "icon": "castle", "color": "113CCF"},
    {"name": "Max", "target": "https://play.max.com", "icon": "sparkle", "color": "0046FF"},
    {"name": "Hulu", "target": "https://www.hulu.com", "icon": "tv", "color": "1CE783"},
    {"name": "Twitch", "target": "https://www.twitch.tv", "icon": "game", "color": "9146FF"},
    {"name": "VLC", "target": "vlc.exe", "icon": "play", "color": "FF8800"},
    {"name": "Kodi", "target": "kodi.exe", "icon": "video", "color": "17B2E7"},
]


def _clean(entry):
    """Coerce one entry to the known shape; return None if unusable."""
    if not isinstance(entry, dict):
        return None
    name = str(entry.get("name", "")).strip()
    target = str(entry.get("target", "")).strip()
    if not name or not target:
        return None
    icon = (str(entry.get("icon", "app")).strip().lower() or "app")
    color = str(entry.get("color", "")).strip().lstrip("#").upper()
    if len(color) != 6 or any(c not in "0123456789ABCDEF" for c in color):
        color = "4F8CFF"
    return {"name": name[:40], "target": target, "icon": icon, "color": color}


def load_apps():
    """Return the saved app list, seeding defaults the first time."""
    try:
        with open(APPS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        apps = [c for c in (_clean(e) for e in data) if c]
        if apps:
            return apps
    except (OSError, ValueError):
        pass
    # First run / unreadable / empty -> seed defaults.
    return save_apps(DEFAULTS)


def save_apps(apps):
    """Persist the app list (best-effort); returns the cleaned list."""
    cleaned = [c for c in (_clean(e) for e in apps) if c]
    try:
        os.makedirs(os.path.dirname(APPS_FILE), exist_ok=True)
        with open(APPS_FILE, "w", encoding="utf-8") as f:
            json.dump(cleaned, f, indent=2)
    except OSError:
        pass
    return cleaned
