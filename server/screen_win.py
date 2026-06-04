"""
On-demand screen capture for the browser remote's "Quick View".

Grabs the whole virtual desktop, downscales it inside GDI (fast, native), and
returns a PNG built with the standard library only -- ctypes for the capture,
zlib for the compression. Nothing is ever written to disk: the bytes are handed
straight to the WebSocket and forgotten.

Deliberately does NOT touch the process DPI-awareness state (that would disturb
the Tkinter server window); on a scaled display we simply capture at the logical
resolution, which is plenty for a quick look.
"""
import ctypes
import struct
import zlib
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

# Longest side of the returned image. Downscale-only -- never upscale. Big
# enough to read most on-screen text after zooming, small enough to stay snappy.
MAX_DIM = 1600

SRCCOPY = 0x00CC0020
HALFTONE = 4              # best-quality StretchBlt downscale (averages pixels)
DIB_RGB_COLORS = 0
BI_RGB = 0

SM_CXSCREEN = 0
SM_CYSCREEN = 1
SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79

HANDLE = ctypes.c_void_p  # pointer-width -- avoids 64-bit handle truncation


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = (
        ("biSize", wintypes.DWORD),
        ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    )


# Every call that takes or returns a handle MUST be typed, or ctypes defaults to
# c_int and silently truncates pointers on 64-bit Python.
user32.GetDC.argtypes = (HANDLE,)
user32.GetDC.restype = HANDLE
user32.ReleaseDC.argtypes = (HANDLE, HANDLE)
user32.ReleaseDC.restype = ctypes.c_int
user32.GetSystemMetrics.argtypes = (ctypes.c_int,)
user32.GetSystemMetrics.restype = ctypes.c_int

gdi32.CreateCompatibleDC.argtypes = (HANDLE,)
gdi32.CreateCompatibleDC.restype = HANDLE
gdi32.CreateCompatibleBitmap.argtypes = (HANDLE, ctypes.c_int, ctypes.c_int)
gdi32.CreateCompatibleBitmap.restype = HANDLE
gdi32.SelectObject.argtypes = (HANDLE, HANDLE)
gdi32.SelectObject.restype = HANDLE
gdi32.DeleteObject.argtypes = (HANDLE,)
gdi32.DeleteObject.restype = ctypes.c_int
gdi32.DeleteDC.argtypes = (HANDLE,)
gdi32.DeleteDC.restype = ctypes.c_int
gdi32.SetStretchBltMode.argtypes = (HANDLE, ctypes.c_int)
gdi32.SetStretchBltMode.restype = ctypes.c_int
gdi32.SetBrushOrgEx.argtypes = (HANDLE, ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
gdi32.SetBrushOrgEx.restype = ctypes.c_int
gdi32.StretchBlt.argtypes = (
    HANDLE, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    HANDLE, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wintypes.DWORD,
)
gdi32.StretchBlt.restype = ctypes.c_int
gdi32.GetDIBits.argtypes = (
    HANDLE, HANDLE, wintypes.UINT, wintypes.UINT,
    ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT,
)
gdi32.GetDIBits.restype = ctypes.c_int


def _png(rgb, w, h):
    """Encode contiguous RGB bytes as a PNG (8-bit, color type 2). Stdlib only."""
    stride = w * 3
    raw = bytearray()
    for y in range(h):
        raw.append(0)                      # filter type 0 (none) per scanline
        raw += rgb[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 6)

    def chunk(tag, data):
        return (struct.pack("!I", len(data)) + tag + data +
                struct.pack("!I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack("!IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", comp) +
            chunk(b"IEND", b""))


def capture_png(max_dim=MAX_DIM):
    """Capture the desktop and return (png_bytes, width, height)."""
    sx = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
    sy = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    sw = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
    sh = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
    if sw <= 0 or sh <= 0:                 # multi-monitor metrics unavailable
        sx = sy = 0
        sw = user32.GetSystemMetrics(SM_CXSCREEN)
        sh = user32.GetSystemMetrics(SM_CYSCREEN)
    if sw <= 0 or sh <= 0:
        raise OSError("could not read screen size")

    scale = min(1.0, float(max_dim) / max(sw, sh))   # downscale-only
    tw = max(1, int(sw * scale))
    th = max(1, int(sh * scale))

    screen = user32.GetDC(0)
    if not screen:
        raise OSError("GetDC failed")
    memdc = gdi32.CreateCompatibleDC(screen)
    bmp = gdi32.CreateCompatibleBitmap(screen, tw, th)
    old = gdi32.SelectObject(memdc, bmp)
    try:
        gdi32.SetStretchBltMode(memdc, HALFTONE)
        gdi32.SetBrushOrgEx(memdc, 0, 0, None)
        if not gdi32.StretchBlt(memdc, 0, 0, tw, th,
                                screen, sx, sy, sw, sh, SRCCOPY):
            raise OSError("StretchBlt failed")

        bmi = BITMAPINFOHEADER()
        bmi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bmi.biWidth = tw
        bmi.biHeight = -th                 # negative -> top-down rows
        bmi.biPlanes = 1
        bmi.biBitCount = 32
        bmi.biCompression = BI_RGB

        buf = (ctypes.c_char * (tw * th * 4))()
        if gdi32.GetDIBits(memdc, bmp, 0, th, buf,
                           ctypes.byref(bmi), DIB_RGB_COLORS) == 0:
            raise OSError("GetDIBits failed")
        data = bytes(buf)                  # BGRA, top-down
    finally:
        gdi32.SelectObject(memdc, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(memdc)
        user32.ReleaseDC(0, screen)

    # BGRA -> RGB by strided slice assignment (done in C, no per-pixel Python).
    rgb = bytearray(tw * th * 3)
    rgb[0::3] = data[2::4]                  # R
    rgb[1::3] = data[1::4]                  # G
    rgb[2::3] = data[0::4]                  # B
    return _png(rgb, tw, th), tw, th


if __name__ == "__main__":
    png, w, h = capture_png()
    sig = bytes([0x89]) + b"PNG\r\n" + bytes([0x1A, 0x0A])
    print(f"captured {w}x{h}, png {len(png)} bytes, sig ok = {png[:8] == sig}")
