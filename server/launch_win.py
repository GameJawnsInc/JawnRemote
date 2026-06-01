"""
Launch apps, files, or URLs on Windows for the phone's quick-launch remote.

Uses the shell's default "open" handler (like double-clicking), so a single
target string covers web URLs (https://...), protocol URIs (spotify:, steam:),
document paths, and -- via a `start` fallback -- apps registered under the
Windows "App Paths" key or on PATH (vlc.exe, kodi.exe, notepad, ...).

Zero external dependencies. The phone sends the target; the curated app list
lives in the app, so it can grow without anyone reinstalling this server.
"""
import os
import subprocess

CREATE_NO_WINDOW = 0x08000000


def launch(target):
    """Open a URL / protocol / file / app. Returns True if something was started."""
    target = str(target).strip()
    if not target:
        return False
    # 1) Shell "open" verb: handles http(s) URLs, protocol URIs, and file paths
    #    exactly like double-clicking them.
    try:
        os.startfile(target)  # noqa: S606 - intentional shell open (Windows only)
        return True
    except (OSError, ValueError):
        pass
    # 2) Fallback: the shell `start` verb also resolves bare app names through the
    #    App Paths registry / PATH (e.g. "vlc.exe", "kodi.exe", "notepad").
    try:
        subprocess.Popen(["cmd", "/c", "start", "", target],
                         creationflags=CREATE_NO_WINDOW)
        return True
    except OSError:
        return False
