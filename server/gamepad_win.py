"""
Virtual Xbox 360 gamepad via ViGEmBus, driven through ViGEmClient.dll with
ctypes -- no pip dependencies, matching the rest of the server.

The pad is *stateful*: callers set its full current state and ViGEm holds it
until the next update -- the natural "press and hold to walk" model. There are
no key-repeat hacks; a held button stays held until the next state says
otherwise.

Requirements at runtime:
  * the ViGEmBus driver installed (a signed kernel driver), and
  * ViGEmClient.dll (x64, matching the Python build) reachable -- bundled beside
    the server / exe, in a `vendor\\` subfolder, on PATH, or pointed at by the
    JR_VIGEM_DLL environment variable.

Every entry point degrades to a no-op / False when the driver or DLL is missing,
so a machine without gamepad support runs the rest of the server unchanged.
"""
import ctypes
import os
import sys
import threading

# XInput / XUSB button bits (ViGEm XUSB_BUTTON_*). These names are exactly what
# the wire protocol uses when a `pad` message lists buttons by name.
BUTTON_BITS = {
    "up": 0x0001, "down": 0x0002, "left": 0x0004, "right": 0x0008,
    "start": 0x0010, "back": 0x0020,
    "ls": 0x0040, "rs": 0x0080,        # L3 / R3 (stick clicks)
    "lb": 0x0100, "rb": 0x0200,        # shoulders
    "guide": 0x0400,                   # Xbox / Guide button
    "a": 0x1000, "b": 0x2000, "x": 0x4000, "y": 0x8000,
}

_S16_MIN, _S16_MAX = -32768, 32767
VIGEM_ERROR_NONE = 0x20000000


class _XUSBReport(ctypes.Structure):
    """Mirrors ViGEm's XUSB_REPORT (== XInput XINPUT_GAMEPAD layout)."""
    _fields_ = (
        ("wButtons", ctypes.c_ushort),
        ("bLeftTrigger", ctypes.c_ubyte),
        ("bRightTrigger", ctypes.c_ubyte),
        ("sThumbLX", ctypes.c_short),
        ("sThumbLY", ctypes.c_short),
        ("sThumbRX", ctypes.c_short),
        ("sThumbRY", ctypes.c_short),
    )


def _clampi(v, lo, hi):
    try:
        v = int(v)
    except (TypeError, ValueError):
        return 0
    return lo if v < lo else hi if v > hi else v


def _dll_candidates():
    """Yield plausible ViGEmClient.dll locations, most-specific first."""
    env = os.environ.get("JR_VIGEM_DLL")
    if env:
        yield env
    here = os.path.dirname(os.path.abspath(__file__))
    frozen = getattr(sys, "_MEIPASS", None)            # PyInstaller bundle dir
    exedir = os.path.dirname(os.path.abspath(sys.executable))
    seen = set()
    for base in (here, frozen, exedir):
        if not base or base in seen:
            continue
        seen.add(base)
        yield os.path.join(base, "ViGEmClient.dll")
        yield os.path.join(base, "vendor", "ViGEmClient.dll")
    # Last resort: let the OS loader search PATH / system directories.
    yield "ViGEmClient.dll"


def buttons_from_names(names):
    mask = 0
    for n in names or ():
        mask |= BUTTON_BITS.get(str(n).lower(), 0)
    return mask


class _Pad:
    """Process-wide singleton holding one virtual Xbox 360 controller."""

    def __init__(self):
        self._lock = threading.RLock()
        self._dll = None
        self._bus = None        # PVIGEM_CLIENT
        self._target = None     # PVIGEM_TARGET (x360)
        self._tried_load = False
        self._error = None

    # ---- DLL loading -----------------------------------------------------
    def _load_dll(self):
        if self._tried_load:
            return self._dll is not None
        self._tried_load = True
        dll = None
        for cand in _dll_candidates():
            if cand != "ViGEmClient.dll" and not os.path.isfile(cand):
                continue
            try:
                dll = ctypes.WinDLL(cand)
                break
            except OSError:
                dll = None
        if dll is None:
            self._error = "ViGEmClient.dll not found (need the x64 build)"
            return False
        try:
            dll.vigem_alloc.restype = ctypes.c_void_p
            dll.vigem_free.argtypes = [ctypes.c_void_p]
            dll.vigem_connect.argtypes = [ctypes.c_void_p]
            dll.vigem_connect.restype = ctypes.c_uint
            dll.vigem_disconnect.argtypes = [ctypes.c_void_p]
            dll.vigem_target_x360_alloc.restype = ctypes.c_void_p
            dll.vigem_target_free.argtypes = [ctypes.c_void_p]
            dll.vigem_target_add.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            dll.vigem_target_add.restype = ctypes.c_uint
            dll.vigem_target_remove.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            dll.vigem_target_remove.restype = ctypes.c_uint
            dll.vigem_target_x360_update.argtypes = [
                ctypes.c_void_p, ctypes.c_void_p, _XUSBReport]
            dll.vigem_target_x360_update.restype = ctypes.c_uint
        except AttributeError as e:
            self._error = f"ViGEmClient.dll missing a symbol: {e}"
            return False
        self._dll = dll
        return True

    # ---- lifecycle -------------------------------------------------------
    def available(self):
        with self._lock:
            return self._load_dll()

    def plug(self):
        """Create + plug in the virtual pad. Idempotent. True if one is live."""
        with self._lock:
            if self._target is not None:
                return True
            if not self._load_dll():
                return False
            if self._bus is None:
                bus = self._dll.vigem_alloc()
                if not bus:
                    self._error = "vigem_alloc failed"
                    return False
                rc = self._dll.vigem_connect(bus)
                if rc != VIGEM_ERROR_NONE:
                    self._dll.vigem_free(bus)
                    self._error = f"vigem_connect failed 0x{rc & 0xFFFFFFFF:08X} (driver not ready?)"
                    return False
                self._bus = bus
            target = self._dll.vigem_target_x360_alloc()
            if not target:
                self._error = "vigem_target_x360_alloc failed"
                return False
            rc = self._dll.vigem_target_add(self._bus, target)
            if rc != VIGEM_ERROR_NONE:
                self._dll.vigem_target_free(target)
                self._error = f"vigem_target_add failed 0x{rc & 0xFFFFFFFF:08X}"
                return False
            self._target = target
            self._error = None
            self._update(_XUSBReport())     # start neutral
            return True

    def _update(self, report):
        if self._target is None:
            return False
        try:
            return self._dll.vigem_target_x360_update(
                self._bus, self._target, report) == VIGEM_ERROR_NONE
        except OSError:
            return False

    def apply(self, buttons=0, lt=0, rt=0, lx=0, ly=0, rx=0, ry=0):
        with self._lock:
            if self._target is None:
                # Auto-plug on first state so a `pad` message works even if an
                # explicit padconnect was missed or raced.
                if not self.plug():
                    return False
            r = _XUSBReport()
            r.wButtons = int(buttons) & 0xFFFF
            r.bLeftTrigger = _clampi(lt, 0, 255)
            r.bRightTrigger = _clampi(rt, 0, 255)
            r.sThumbLX = _clampi(lx, _S16_MIN, _S16_MAX)
            r.sThumbLY = _clampi(ly, _S16_MIN, _S16_MAX)
            r.sThumbRX = _clampi(rx, _S16_MIN, _S16_MAX)
            r.sThumbRY = _clampi(ry, _S16_MIN, _S16_MAX)
            return self._update(r)

    def neutralize(self):
        """Release every input (sticks centered, buttons up). The failsafe."""
        with self._lock:
            return self._update(_XUSBReport())

    def unplug(self):
        with self._lock:
            if self._target is not None:
                try:
                    self._update(_XUSBReport())     # release before unplug
                    self._dll.vigem_target_remove(self._bus, self._target)
                    self._dll.vigem_target_free(self._target)
                except OSError:
                    pass
                self._target = None
            return True

    def last_error(self):
        return self._error


_pad = _Pad()


# ---- module-level API ----------------------------------------------------
def available():
    return _pad.available()


def plug():
    return _pad.plug()


def unplug():
    return _pad.unplug()


def neutralize():
    return _pad.neutralize()


def apply(buttons=0, lt=0, rt=0, lx=0, ly=0, rx=0, ry=0):
    return _pad.apply(buttons=buttons, lt=lt, rt=rt, lx=lx, ly=ly,
                      rx=rx, ry=ry)


def last_error():
    return _pad.last_error()


def apply_msg(msg):
    """Apply one wire `pad` message. `b` may be an int bitmask or a list of
    button names; sticks (lx/ly/rx/ry, int16) and triggers (lt/rt, 0-255) are
    clamped. Returns True if the pad accepted the state."""
    b = msg.get("b", 0)
    buttons = buttons_from_names(b) if isinstance(b, (list, tuple)) else (
        int(b) if isinstance(b, (int, float)) else 0)
    if "buttons" in msg:
        buttons |= buttons_from_names(msg.get("buttons"))

    def num(k):
        try:
            return int(msg.get(k, 0))
        except (TypeError, ValueError):
            return 0

    return _pad.apply(buttons=buttons, lt=num("lt"), rt=num("rt"),
                      lx=num("lx"), ly=num("ly"), rx=num("rx"), ry=num("ry"))
