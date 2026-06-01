"""
System power actions for the JawnRemote server: lock, sleep, shut down, restart,
log off. Windows-only (ctypes + the built-in `shutdown` command). The phone app
confirms the destructive actions (shutdown/restart/log off) before sending them.
"""
import ctypes
import subprocess

# Keep the `shutdown` command from flashing a console window.
_CREATE_NO_WINDOW = 0x08000000


def _shutdown(*args):
    subprocess.Popen(["shutdown", *args], creationflags=_CREATE_NO_WINDOW)


def lock():
    ctypes.windll.user32.LockWorkStation()


def sleep():
    # SetSuspendState(bHibernate=0, bForce=1, bWakeupEventsDisabled=0) -> sleep.
    ctypes.windll.powrprof.SetSuspendState(0, 1, 0)


def shutdown():
    _shutdown("/s", "/t", "0")


def restart():
    _shutdown("/r", "/t", "0")


def logoff():
    _shutdown("/l")


_ACTIONS = {
    "lock": lock,
    "sleep": sleep,
    "shutdown": shutdown,
    "restart": restart,
    "logoff": logoff,
    "logout": logoff,
}


def power(action):
    """Run a named power action. Returns True if the action was recognized."""
    fn = _ACTIONS.get(str(action).lower())
    if not fn:
        return False
    fn()
    return True
