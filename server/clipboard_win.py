"""Read/write the Windows clipboard (Unicode text) via ctypes. No deps.

Used by clipboard sync: the phone can pull the PC's clipboard or push text onto
it. Failures are swallowed and reported as "" / False. Opening the clipboard is
retried briefly, since clipboard history, cloud clipboard, rdpclip, password
managers etc. hold it for a moment right after every copy.
"""
import ctypes
import time
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
kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]
kernel32.GlobalFree.restype = wintypes.HGLOBAL


def _open(timeout=0.5):
    """OpenClipboard, retrying while another app holds it. True if opened."""
    deadline = time.monotonic() + timeout
    while True:
        if user32.OpenClipboard(None):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


def get_text():
    """Return the clipboard's Unicode text, or '' if empty/unavailable."""
    if not _open():
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
    # NUL-terminated. 'surrogatepass': a lone surrogate is still valid UTF-16.
    data = str(s).encode("utf-16-le", "surrogatepass") + b"\x00\x00"
    # Build the memory block before opening the clipboard, so a failure here
    # can't leave the PC's clipboard emptied.
    handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(data))
    if not handle:
        return False
    ptr = kernel32.GlobalLock(handle)
    if not ptr:
        kernel32.GlobalFree(handle)
        return False
    ctypes.memmove(ptr, data, len(data))
    kernel32.GlobalUnlock(handle)
    if not _open():
        kernel32.GlobalFree(handle)
        return False
    try:
        user32.EmptyClipboard()
        # On success the system owns `handle`; otherwise it's still ours.
        if user32.SetClipboardData(CF_UNICODETEXT, handle):
            return True
        kernel32.GlobalFree(handle)
        return False
    finally:
        user32.CloseClipboard()
