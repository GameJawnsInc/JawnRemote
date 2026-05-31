"""
System-tray icon for the JawnRemote server, implemented with pure ctypes
(Shell_NotifyIcon). No third-party packages, so it adds ~nothing to the bundle
(the .ico is already shipped).

Design: it subclasses the host window's WndProc on the main (tkinter) thread, so
tray callbacks run where it is safe to touch tkinter -- no extra threads, no
cross-thread marshaling. Unhandled messages are forwarded to tkinter's original
WndProc, so the window keeps working normally (including the WM_DELETE_WINDOW
protocol the host uses to hide-to-tray).

Usage:
    hwnd = tray_win.host_hwnd(root)
    tray = tray_win.TrayIcon(hwnd, ico_path, "tooltip",
                             on_show=..., on_quit=...)   # both fire on the tk thread
    tray.show_balloon("Title", "message")
    tray.remove()
"""
import ctypes
from ctypes import wintypes

user32 = ctypes.windll.user32
shell32 = ctypes.windll.shell32

# --- pointer-sized types (correct on both 32- and 64-bit) ---
LRESULT = ctypes.c_ssize_t
ULONG_PTR = ctypes.c_size_t

WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wintypes.HWND, wintypes.UINT,
                             wintypes.WPARAM, wintypes.LPARAM)


def _proto(fn, restype, argtypes):
    # Setting restype/argtypes is essential on 64-bit: without it ctypes assumes
    # a 32-bit int return and truncates HWND/HMENU/proc pointers to garbage.
    fn.restype = restype
    fn.argtypes = argtypes
    return fn


_proto(user32.GetAncestor, wintypes.HWND, [wintypes.HWND, wintypes.UINT])
_proto(user32.GetParent, wintypes.HWND, [wintypes.HWND])
_proto(user32.DefWindowProcW, LRESULT,
       [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM])
_proto(user32.CallWindowProcW, LRESULT,
       [ctypes.c_void_p, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM])
_proto(user32.LoadImageW, wintypes.HANDLE,
       [wintypes.HINSTANCE, wintypes.LPCWSTR, wintypes.UINT, ctypes.c_int,
        ctypes.c_int, wintypes.UINT])
_proto(user32.LoadIconW, wintypes.HANDLE, [wintypes.HINSTANCE, ctypes.c_void_p])
_proto(user32.DestroyIcon, wintypes.BOOL, [wintypes.HANDLE])
_proto(user32.CreatePopupMenu, wintypes.HMENU, [])
_proto(user32.AppendMenuW, wintypes.BOOL,
       [wintypes.HMENU, wintypes.UINT, ULONG_PTR, wintypes.LPCWSTR])
_proto(user32.TrackPopupMenu, wintypes.BOOL,
       [wintypes.HMENU, wintypes.UINT, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        wintypes.HWND, ctypes.c_void_p])
_proto(user32.DestroyMenu, wintypes.BOOL, [wintypes.HMENU])
_proto(user32.GetCursorPos, wintypes.BOOL, [ctypes.POINTER(wintypes.POINT)])
_proto(user32.SetForegroundWindow, wintypes.BOOL, [wintypes.HWND])
_proto(user32.PostMessageW, wintypes.BOOL,
       [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM])
_proto(user32.GetSystemMetrics, ctypes.c_int, [ctypes.c_int])

# SetWindowLongPtrW exists on 64-bit; on 32-bit it is a macro for SetWindowLongW.
if hasattr(user32, "SetWindowLongPtrW"):
    _SetWindowLongPtr = user32.SetWindowLongPtrW
    _GetWindowLongPtr = user32.GetWindowLongPtrW
else:
    _SetWindowLongPtr = user32.SetWindowLongW
    _GetWindowLongPtr = user32.GetWindowLongW
_proto(_SetWindowLongPtr, ctypes.c_void_p,
       [wintypes.HWND, ctypes.c_int, ctypes.c_void_p])
_proto(_GetWindowLongPtr, ctypes.c_void_p, [wintypes.HWND, ctypes.c_int])


class GUID(ctypes.Structure):
    _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]


class NOTIFYICONDATAW(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("hWnd", wintypes.HWND),
        ("uID", wintypes.UINT),
        ("uFlags", wintypes.UINT),
        ("uCallbackMessage", wintypes.UINT),
        ("hIcon", wintypes.HICON),
        ("szTip", wintypes.WCHAR * 128),
        ("dwState", wintypes.DWORD),
        ("dwStateMask", wintypes.DWORD),
        ("szInfo", wintypes.WCHAR * 256),
        ("uVersion", wintypes.UINT),
        ("szInfoTitle", wintypes.WCHAR * 64),
        ("dwInfoFlags", wintypes.DWORD),
        ("guidItem", GUID),
        ("hBalloonIcon", wintypes.HICON),
    ]


Shell_NotifyIconW = shell32.Shell_NotifyIconW
Shell_NotifyIconW.restype = wintypes.BOOL
Shell_NotifyIconW.argtypes = [wintypes.DWORD, ctypes.POINTER(NOTIFYICONDATAW)]

# --- constants ---
GA_ROOT = 2
GWLP_WNDPROC = -4
WM_APP = 0x8000
TRAY_CALLBACK = WM_APP + 1
WM_NULL = 0x0000
WM_LBUTTONUP = 0x0202
WM_LBUTTONDBLCLK = 0x0203
WM_RBUTTONUP = 0x0205
WM_CONTEXTMENU = 0x007B

NIM_ADD, NIM_MODIFY, NIM_DELETE = 0, 1, 2
NIF_MESSAGE, NIF_ICON, NIF_TIP, NIF_INFO = 0x01, 0x02, 0x04, 0x10
NIIF_INFO = 0x01
TIP_FLAGS = NIF_MESSAGE | NIF_ICON | NIF_TIP

IMAGE_ICON = 1
LR_LOADFROMFILE = 0x0010
IDI_APPLICATION = 32512
SM_CXSMICON, SM_CYSMICON = 49, 50

MF_STRING = 0x0000
MF_SEPARATOR = 0x0800
TPM_RIGHTBUTTON = 0x0002
TPM_RETURNCMD = 0x0100

_ID_SHOW = 1
_ID_QUIT = 2


def host_hwnd(tk_window):
    """Real top-level OS window handle behind a tkinter root/toplevel."""
    wid = tk_window.winfo_id()
    return user32.GetAncestor(wid, GA_ROOT) or user32.GetParent(wid) or wid


class TrayIcon:
    def __init__(self, hwnd, icon_path, tooltip, on_show, on_quit):
        self.hwnd = hwnd
        self.on_show = on_show
        self.on_quit = on_quit
        self._removed = False

        # Load the icon at small-icon size; fall back to the generic app icon.
        cx = user32.GetSystemMetrics(SM_CXSMICON) or 16
        cy = user32.GetSystemMetrics(SM_CYSMICON) or 16
        self._owns_icon = False
        self._hicon = 0
        if icon_path:
            self._hicon = user32.LoadImageW(None, icon_path, IMAGE_ICON, cx, cy,
                                            LR_LOADFROMFILE)
            self._owns_icon = bool(self._hicon)
        if not self._hicon:
            self._hicon = user32.LoadIconW(None, ctypes.c_void_p(IDI_APPLICATION))

        # Subclass the host window so tray callbacks arrive on this (tk) thread.
        # Keep the WNDPROC object alive on self, or it gets GC'd and we crash.
        self._wndproc = WNDPROC(self._handle)
        self._old_proc = _SetWindowLongPtr(
            hwnd, GWLP_WNDPROC, ctypes.cast(self._wndproc, ctypes.c_void_p))

        nid = NOTIFYICONDATAW()
        nid.cbSize = ctypes.sizeof(NOTIFYICONDATAW)
        nid.hWnd = hwnd
        nid.uID = 1
        nid.uFlags = TIP_FLAGS
        nid.uCallbackMessage = TRAY_CALLBACK
        nid.hIcon = self._hicon
        nid.szTip = (tooltip or "")[:127]
        Shell_NotifyIconW(NIM_ADD, ctypes.byref(nid))
        self._nid = nid

    # --- WndProc (runs on the tkinter thread) ---
    def _handle(self, hwnd, msg, wparam, lparam):
        if msg == TRAY_CALLBACK:
            event = lparam & 0xFFFF
            if event in (WM_LBUTTONUP, WM_LBUTTONDBLCLK):
                self._safe(self.on_show)
            elif event in (WM_RBUTTONUP, WM_CONTEXTMENU):
                self._popup()
            return 0
        if self._old_proc:
            return user32.CallWindowProcW(self._old_proc, hwnd, msg, wparam, lparam)
        return user32.DefWindowProcW(hwnd, msg, wparam, lparam)

    def _popup(self):
        menu = user32.CreatePopupMenu()
        user32.AppendMenuW(menu, MF_STRING, _ID_SHOW, "Show JawnRemote")
        user32.AppendMenuW(menu, MF_SEPARATOR, 0, None)
        user32.AppendMenuW(menu, MF_STRING, _ID_QUIT, "Quit")
        pt = wintypes.POINT()
        user32.GetCursorPos(ctypes.byref(pt))
        # Required so the menu dismisses on click-away and gets keyboard focus.
        user32.SetForegroundWindow(self.hwnd)
        cmd = user32.TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD,
                                    pt.x, pt.y, 0, self.hwnd, None)
        user32.PostMessageW(self.hwnd, WM_NULL, 0, 0)
        user32.DestroyMenu(menu)
        if cmd == _ID_SHOW:
            self._safe(self.on_show)
        elif cmd == _ID_QUIT:
            self._safe(self.on_quit)

    @staticmethod
    def _safe(cb):
        try:
            if cb:
                cb()
        except Exception:
            pass

    def show_balloon(self, title, message):
        if self._removed:
            return
        self._nid.uFlags = TIP_FLAGS | NIF_INFO
        self._nid.szInfo = (message or "")[:255]
        self._nid.szInfoTitle = (title or "")[:63]
        self._nid.dwInfoFlags = NIIF_INFO
        Shell_NotifyIconW(NIM_MODIFY, ctypes.byref(self._nid))
        self._nid.uFlags = TIP_FLAGS

    def remove(self):
        if self._removed:
            return
        self._removed = True
        try:
            Shell_NotifyIconW(NIM_DELETE, ctypes.byref(self._nid))
        except Exception:
            pass
        try:
            if self._old_proc:
                _SetWindowLongPtr(self.hwnd, GWLP_WNDPROC, self._old_proc)
        except Exception:
            pass
        try:
            if self._owns_icon and self._hicon:
                user32.DestroyIcon(self._hicon)
        except Exception:
            pass
