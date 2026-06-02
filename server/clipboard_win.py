"""Read/write the Windows clipboard (Unicode text) via ctypes. No deps.

Used by clipboard sync: the phone can pull the PC's clipboard or push text onto
it. Failures are swallowed and reported as "" / False (the clipboard can be
briefly locked by another app).
"""
import ctypes
from ctypes import wintypes

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

user32.OpenClipboard.argtypes = [wintypes.HWND]
user32.OpenClipboard.restype = wintypes.BOOL
user32.CloseClipboard.restype = wintypes.BOOL
user32.EmptyClipboard.restype = wintypes.BOOL
user32.GetClipboardData.argtypes = [wintypes.UINT]
user32.GetClipboardData.restype = wintypes.HANDLE
user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
user32.SetClipboardData.restype = wintypes.HANDLE

kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
kernel32.GlobalLock.restype = wintypes.LPVOID
kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
kernel32.GlobalUnlock.restype = wintypes.BOOL
kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
kernel32.GlobalAlloc.restype = wintypes.HGLOBAL


def get_text():
    """Return the clipboard's Unicode text, or '' if empty/unavailable."""
    if not user32.OpenClipboard(None):
        return ""
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return ""
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            return ""
        try:
            return ctypes.wstring_at(ptr)
        finally:
            kernel32.GlobalUnlock(handle)
    except OSError:
        return ""
    finally:
        user32.CloseClipboard()


def set_text(s):
    """Put Unicode text on the clipboard. Returns True on success."""
    s = str(s)
    if not user32.OpenClipboard(None):
        return False
    try:
        user32.EmptyClipboard()
        data = s.encode("utf-16-le") + b"\x00\x00"  # NUL-terminated
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not handle:
            return False
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            return False
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(handle)
        # On success the system owns `handle`; don't free it.
        return bool(user32.SetClipboardData(CF_UNICODETEXT, handle))
    except OSError:
        return False
    finally:
        user32.CloseClipboard()
