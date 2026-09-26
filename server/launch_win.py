"""
Launch apps, files, or URLs on Windows for the phone's quick-launch remote.

Uses the shell's default "open" handler (ShellExecute, like double-clicking), so
a single target string covers web URLs (https://...), protocol URIs (spotify:,
steam:), document paths, and apps registered under the Windows "App Paths" key
or on PATH (vlc.exe, kodi.exe, notepad, ...). A target that can't be opened
(e.g. an app that isn't installed) just returns False -- no "Windows cannot
find" dialog is left on the PC.

Zero external dependencies. The phone sends the target; the curated app list
lives in the app, so it can grow without anyone reinstalling this server.
"""
import os
import shutil


def launch(target):
    """Open a URL / protocol / file / app. Returns True if something was
    started, False if it couldn't be found / opened."""
    # Also drops the quotes Explorer's "Copy as path" puts around a path.
    target = str(target).strip().strip('"').strip()
    if not target:
        return False
    # 1) Shell "open" verb: handles http(s) URLs, protocol URIs, file paths and
    #    App Paths / PATH names exactly like double-clicking them. It fails
    #    silently (OSError) rather than showing an error dialog.
    try:
        os.startfile(target)  # noqa: S606 - intentional shell open (Windows only)
        return True
    except (OSError, ValueError):
        pass
    # 2) Fallback: a program on PATH that the shell didn't resolve by name.
    try:
        exe = shutil.which(target)
        if exe:
            os.startfile(exe)  # noqa: S606
            return True
    except (OSError, ValueError):
        pass
    return False
