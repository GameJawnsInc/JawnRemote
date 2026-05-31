"""
Win32 input injection via SendInput (ctypes, no external dependencies).

Provides relative mouse movement, buttons, scroll wheel, Unicode text typing,
and named special keys with modifier combos (e.g. Ctrl+C).

Struct layout is carefully sized for 64-bit Python (ULONG_PTR == c_size_t).
"""
import ctypes
from ctypes import wintypes

user32 = ctypes.WinDLL("user32", use_last_error=True)

# ---- input type ----
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

# ---- mouse event flags ----
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_XDOWN = 0x0080
MOUSEEVENTF_XUP = 0x0100
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x1000
WHEEL_DELTA = 120

# ---- keyboard event flags ----
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008

# ULONG_PTR is a pointer-sized *unsigned integer*, not a pointer.
ULONG_PTR = ctypes.c_size_t


class MOUSEINPUT(ctypes.Structure):
    _fields_ = (
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    )


class KEYBDINPUT(ctypes.Structure):
    _fields_ = (
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    )


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = (
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    )


class _INPUT_UNION(ctypes.Union):
    _fields_ = (("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT))


class INPUT(ctypes.Structure):
    _fields_ = (("type", wintypes.DWORD), ("u", _INPUT_UNION))


user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
user32.SendInput.restype = wintypes.UINT

user32.VkKeyScanW.argtypes = (wintypes.WCHAR,)
user32.VkKeyScanW.restype = ctypes.c_short


class POINT(ctypes.Structure):
    _fields_ = (("x", wintypes.LONG), ("y", wintypes.LONG))


user32.GetCursorPos.argtypes = (ctypes.POINTER(POINT),)
user32.GetCursorPos.restype = wintypes.BOOL


def _send(*inputs):
    n = len(inputs)
    if n == 0:
        return 0
    arr = (INPUT * n)(*inputs)
    sent = user32.SendInput(n, arr, ctypes.sizeof(INPUT))
    if sent != n:
        raise ctypes.WinError(ctypes.get_last_error())
    return sent


def _mouse(dx=0, dy=0, data=0, flags=0):
    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp.u.mi = MOUSEINPUT(
        dx=int(dx), dy=int(dy), mouseData=int(data) & 0xFFFFFFFF,
        dwFlags=flags, time=0, dwExtraInfo=0,
    )
    return inp


def _kbd(vk=0, scan=0, flags=0):
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.u.ki = KEYBDINPUT(
        wVk=vk, wScan=scan, dwFlags=flags, time=0, dwExtraInfo=0,
    )
    return inp


# =================== Mouse ===================

_BTN = {
    "left": (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
    "right": (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
    "middle": (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
}


def move(dx, dy):
    """Relative mouse movement."""
    if dx or dy:
        _send(_mouse(dx=dx, dy=dy, flags=MOUSEEVENTF_MOVE))


def mouse_down(button="left"):
    down, _ = _BTN.get(button, _BTN["left"])
    _send(_mouse(flags=down))


def mouse_up(button="left"):
    _, up = _BTN.get(button, _BTN["left"])
    _send(_mouse(flags=up))


def click(button="left"):
    down, up = _BTN.get(button, _BTN["left"])
    _send(_mouse(flags=down), _mouse(flags=up))


def scroll(dy=0, dx=0):
    """Scroll wheel. dy/dx are in wheel units (WHEEL_DELTA == 120 per notch).
    Positive dy scrolls up, positive dx scrolls right."""
    if dy:
        _send(_mouse(data=dy, flags=MOUSEEVENTF_WHEEL))
    if dx:
        _send(_mouse(data=dx, flags=MOUSEEVENTF_HWHEEL))


def get_cursor_pos():
    p = POINT()
    user32.GetCursorPos(ctypes.byref(p))
    return (p.x, p.y)


# =================== Keyboard ===================

def _utf16_units(ch):
    b = ch.encode("utf-16-le")
    return [b[i] | (b[i + 1] << 8) for i in range(0, len(b), 2)]


def type_text(s):
    """Type an arbitrary unicode string via scancode injection (handles any
    character, independent of keyboard layout). Not for shortcuts."""
    inputs = []
    for ch in s:
        for cu in _utf16_units(ch):
            inputs.append(_kbd(scan=cu, flags=KEYEVENTF_UNICODE))
            inputs.append(_kbd(scan=cu, flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP))
    # Send in chunks to stay well under the OS input batch limits.
    for i in range(0, len(inputs), 200):
        _send(*inputs[i:i + 200])


# Virtual-key codes for named keys.
VK = {
    "enter": 0x0D, "return": 0x0D,
    "backspace": 0x08, "tab": 0x09, "escape": 0x1B, "esc": 0x1B,
    "space": 0x20,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "delete": 0x2E, "del": 0x2E, "insert": 0x2D,
    "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
    "capslock": 0x14, "numlock": 0x90, "scrolllock": 0x91, "pause": 0x13,
    "printscreen": 0x2C, "prtsc": 0x2C, "apps": 0x5D, "menu_key": 0x5D,
    "ctrl": 0x11, "control": 0x11, "lctrl": 0xA2, "rctrl": 0xA3,
    "alt": 0x12, "lalt": 0xA4, "ralt": 0xA5,
    "shift": 0x10, "lshift": 0xA0, "rshift": 0xA1,
    "win": 0x5B, "lwin": 0x5B, "rwin": 0x5C, "meta": 0x5B,
    "f1": 0x70, "f2": 0x71, "f3": 0x72, "f4": 0x73, "f5": 0x74, "f6": 0x75,
    "f7": 0x76, "f8": 0x77, "f9": 0x78, "f10": 0x79, "f11": 0x7A, "f12": 0x7B,
    "volumeup": 0xAF, "volumedown": 0xAE, "volumemute": 0xAD, "mute": 0xAD,
    "medianext": 0xB0, "mediaprev": 0xB1, "mediastop": 0xB2,
    "mediaplaypause": 0xB3, "playpause": 0xB3,
    "browserback": 0xA6, "browserforward": 0xA7,
}

# Keys that require the extended-key flag for correct behaviour.
_EXTENDED = {
    0x25, 0x26, 0x27, 0x28,  # arrows
    0x2E, 0x2D, 0x24, 0x23, 0x21, 0x22,  # nav cluster
    0x5B, 0x5C, 0x5D,  # win / apps
    0xA3, 0xA5,  # right ctrl / right alt
    0x2C, 0x90,  # printscreen / numlock
    0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3,  # media
    0xA6, 0xA7,
}

_MODIFIER_NAMES = {"ctrl", "control", "alt", "shift", "win", "meta", "cmd"}


def _ext(vk):
    return KEYEVENTF_EXTENDEDKEY if vk in _EXTENDED else 0


def _vk_for_char(ch):
    """Returns (vk, needs_shift) for a single character, or None."""
    res = user32.VkKeyScanW(ch)
    if res == -1:
        return None
    vk = res & 0xFF
    shift_state = (res >> 8) & 0xFF
    return vk, bool(shift_state & 1)


def key(name, modifiers=()):
    """Press a named key (or single character) with optional modifiers held.
    Used for special keys and shortcuts like Ctrl+C."""
    name_l = str(name).lower()
    mod_vks = []
    for m in modifiers or ():
        m = str(m).lower()
        if m in ("cmd", "meta"):
            m = "win"
        mv = VK.get(m)
        if mv and mv not in mod_vks:
            mod_vks.append(mv)

    seq = []
    for mv in mod_vks:
        seq.append(_kbd(vk=mv, flags=_ext(mv)))

    if name_l in VK:
        vk = VK[name_l]
        seq.append(_kbd(vk=vk, flags=_ext(vk)))
        seq.append(_kbd(vk=vk, flags=_ext(vk) | KEYEVENTF_KEYUP))
    elif len(str(name)) == 1:
        info = _vk_for_char(str(name))
        if info is not None and info[0] != 0xFF:
            vk, needs_shift = info
            add_shift = needs_shift and 0x10 not in mod_vks
            if add_shift:
                seq.append(_kbd(vk=0x10))
            seq.append(_kbd(vk=vk))
            seq.append(_kbd(vk=vk, flags=KEYEVENTF_KEYUP))
            if add_shift:
                seq.append(_kbd(vk=0x10, flags=KEYEVENTF_KEYUP))
        elif not mod_vks:
            type_text(str(name))

    for mv in reversed(mod_vks):
        seq.append(_kbd(vk=mv, flags=_ext(mv) | KEYEVENTF_KEYUP))

    if seq:
        _send(*seq)


if __name__ == "__main__":
    # Tiny self-test: nudge the cursor and put it back.
    import time
    x0, y0 = get_cursor_pos()
    print("cursor at", (x0, y0))
    move(40, 0)
    time.sleep(0.05)
    x1, y1 = get_cursor_pos()
    print("after move:", (x1, y1), "delta", (x1 - x0, y1 - y0))
    move(-40, 0)
    print("INPUT struct size:", ctypes.sizeof(INPUT), "(expect 40 on x64)")
