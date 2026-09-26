"""
JawnRemote server -- friendly GUI version (no console window).

Shows the connection address, PIN, and live status; offers a one-click
"Allow through firewall" button (self-elevates) and a "start at login" toggle.
This is the build that ships to end users (packaged as a single .exe).
"""
import os
import sys
import socket
import queue
import subprocess
import threading
import time
import traceback
import webbrowser
import ctypes
import winreg

import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, messagebox

import server as srv
import apps_store as appstore
import filexfer as fx
import qr

try:
    import tray_win
except Exception:
    tray_win = None

APP_NAME = "JawnRemote"
PORT = srv.DEFAULT_PORT
FW_RULE = "JawnRemote"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
CREATE_NO_WINDOW = 0x08000000
AUTOSTART_ARG = "--tray"            # sign-in launch: start hidden in the tray
MUTEX_NAME = "JawnRemoteServer"     # also the installer's AppMutex -- keep in sync
SHOW_MSG = "JawnRemoteShow"         # tray_win turns this into its 'show' action
QR_QUIET, QR_SCALE = 4, 4           # QR border (modules) and px per module

BG = "#0E1116"
CARD = "#161C24"
FG = "#FFFFFF"
MUTED = "#8A94A6"
ACCENT = "#4F8CFF"
GREEN = "#3DDC84"
AMBER = "#E8A33D"
RED = "#E85D5D"

_instance_mutex = None              # held (never closed) for the process lifetime


def _short(s, n):
    """s cut to at most n chars with a middle ellipsis, keeping a short file
    extension: ('IMG_20260926_143512_HDR.jpg', 20) -> 'IMG_2026…512_HDR.jpg'."""
    s = str(s)
    if len(s) <= n:
        return s
    root, ext = os.path.splitext(s)
    if len(ext) > 8 or " " in ext:
        root, ext = s, ""
    keep = n - len(ext) - 1
    head = (keep + 1) // 2
    return root[:head] + "…" + root[len(root) - (keep - head):] + ext


def data_dir():
    base = os.environ.get("APPDATA") or os.path.dirname(os.path.abspath(__file__))
    d = os.path.join(base, APP_NAME)
    os.makedirs(d, exist_ok=True)
    return d


def exe_command():
    """Command used for autostart / the path to relaunch this program."""
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    pyw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    return f'"{pyw}" "{os.path.abspath(__file__)}"'


def firewall_ok():
    # netsh's text is localized (and OEM-codepage), so go by its exit code --
    # non-zero when no rule matches; the English check is just a backstop.
    try:
        out = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={FW_RULE}"],
            capture_output=True, creationflags=CREATE_NO_WINDOW)
        return out.returncode == 0 and b"No rules match" not in out.stdout
    except Exception:
        return False


def add_firewall_rules():
    """Add inbound TCP+UDP allow rules (self-elevates with one UAC prompt).

    Scoped to remoteip=localsubnet so only devices on your own network can
    reach the server -- the open port is invisible to the internet. profile=any
    is kept so it works even when Windows marks your Wi-Fi as 'Public'.
    Returns False if the UAC prompt was cancelled (or elevation failed).
    """
    parts = [
        f'netsh advfirewall firewall delete rule name="{FW_RULE}"',
        f'netsh advfirewall firewall delete rule name="{FW_RULE} (discovery)"',
        f'netsh advfirewall firewall add rule name="{FW_RULE}" dir=in '
        f'action=allow protocol=TCP localport={PORT} profile=any remoteip=localsubnet',
        f'netsh advfirewall firewall add rule name="{FW_RULE} (discovery)" dir=in '
        f'action=allow protocol=UDP localport={PORT} profile=any remoteip=localsubnet',
    ]
    cmd = " & ".join(parts)
    rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", f"/c {cmd}",
                                             None, 0)
    return int(rc or 0) > 32


def autostart_enabled():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP_NAME)
        return True
    except OSError:
        return False


def set_autostart(enable):
    """Add/remove the sign-in entry (it starts us hidden in the tray).
    Returns False if the registry change failed."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0,
                            winreg.KEY_SET_VALUE) as k:
            if enable:
                winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ,
                                  f"{exe_command()} {AUTOSTART_ARG}")
            else:
                try:
                    winreg.DeleteValue(k, APP_NAME)
                except FileNotFoundError:
                    pass    # already off
        return True
    except OSError:
        return False


def _claim_single_instance():
    """True if JawnRemote is already running -- after asking that copy to show
    its window. (A second copy would silently co-bind the port on Windows and
    split connections between two tray icons.) Any ctypes trouble -> False,
    i.e. just start normally."""
    global _instance_mutex
    try:
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateMutexW.restype = wintypes.HANDLE
        k32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL,
                                     wintypes.LPCWSTR]
        _instance_mutex = k32.CreateMutexW(None, False, MUTEX_NAME)
        # ERROR_ALREADY_EXISTS, or ERROR_ACCESS_DENIED (held by an elevated copy)
        if ctypes.get_last_error() not in (183, 5):
            return False
        u32 = ctypes.WinDLL("user32")      # own instance: argtypes set here only
        u32.RegisterWindowMessageW.restype = wintypes.UINT
        u32.RegisterWindowMessageW.argtypes = [wintypes.LPCWSTR]
        u32.FindWindowW.restype = wintypes.HWND
        u32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
        u32.AllowSetForegroundWindow.restype = wintypes.BOOL
        u32.AllowSetForegroundWindow.argtypes = [wintypes.DWORD]
        u32.PostMessageW.restype = wintypes.BOOL
        u32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT,
                                     wintypes.WPARAM, wintypes.LPARAM]
        title = f"{APP_NAME} Server"
        hwnd = (u32.FindWindowW("TkTopLevel", title)
                or u32.FindWindowW(None, title))
        msg = u32.RegisterWindowMessageW(SHOW_MSG)
        if hwnd and msg:
            u32.AllowSetForegroundWindow(0xFFFFFFFF)   # ASFW_ANY: may come to front
            u32.PostMessageW(hwnd, msg, 0, 0)
        return True
    except Exception:
        return False


class App:
    def __init__(self, root):
        self.root = root
        self.tray = None                       # set by _setup_tray (after the UI)
        # In the windowed build sys.stderr is None, so an unhandled callback
        # exception would otherwise take the whole app down. Log it instead.
        self.root.report_callback_exception = self._log_exception
        self.events = queue.Queue()
        self.name = socket.gethostname()
        self.ips = srv.get_lan_ips()

        srv.PIN_FILE = os.path.join(data_dir(), "pin.txt")
        appstore.APPS_FILE = os.path.join(data_dir(), "apps.json")
        self.pin = srv.load_or_create_pin(None)

        self._tray_hint = os.path.join(data_dir(), "tray_hint_shown")
        self._web_off_flag = os.path.join(data_dir(), "web_off")
        self._server_error = None     # why the server couldn't start (kept shown)
        self._sessions = []           # live connections' names, oldest first
        self._sending = False         # a GUI -> phone push is running
        self._status_hold = 0.0       # monotonic time until a result stays shown
        self._status_retry = None     # pending after() to re-show the connection
        self._apps_mgr = None
        self._last_balloon = None     # 'hint' | 'file': what a balloon click means
        self._fw_tries = 0
        self._ip_job = None
        self._build_ui()
        if self.autostart_var.get():
            set_autostart(True)       # keep the entry on this copy (+ --tray)
        self._start_server()
        self._poll_events()
        self._refresh_firewall()
        self._setup_tray()
        if self.tray is None:
            self.footer.configure(text="Closing this window stops the server.")
        self._ip_job = self.root.after(15000, self._check_ips)

    def _log_exception(self, exc, value, tb):
        try:
            with open(os.path.join(data_dir(), "error.log"), "a",
                      encoding="utf-8") as f:
                f.write("".join(traceback.format_exception(exc, value, tb)))
                f.write("\n")
        except Exception:
            pass

    # ---- server ----
    def _start_server(self):
        try:
            self.server = srv.build_server(PORT, "0.0.0.0", self.pin, True,
                                           on_event=self._on_event)
        except OSError:
            # Port taken by another program, or in a range Windows reserved
            # (Hyper-V/WSL): explain it instead of dying with a traceback.
            self.server = None
            self._server_error = (f"Can't start: port {PORT} is in use or blocked\n"
                                  "(by another program, or reserved by Windows)")
            self._set_status(self._server_error, RED)
            return
        self.server.web_enabled = self.web_var.get()
        srv.start_discovery(PORT, self.name)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _on_event(self, event, info=""):
        self.events.put((event, info))

    def _poll_events(self):
        try:
            while True:
                event, info = self.events.get_nowait()
                # connected/disconnected come in pairs per session (app socket
                # or browser), so count them: a stale socket reaped after a
                # reconnect, or a closed browser tab, mustn't say "Ready".
                if event == "connected":
                    self._sessions.append(info)
                    self._show_conn_status()
                elif event == "disconnected":
                    try:
                        self._sessions.remove(info)
                    except ValueError:
                        pass
                    self._show_conn_status()
                elif event == "file_in":
                    self._set_status(f"Received {_short(info, 20)} ✓", GREEN)
                    self._hold_status()
                    if self.tray is not None and self.root.state() == "withdrawn":
                        self.tray.show_balloon(
                            "File received",
                            f"{_short(info, 40)} was saved to Downloads\\JawnRemote")
                        self._last_balloon = "file"
                elif event == "ips":
                    self._update_ips(info)
        except queue.Empty:
            pass
        # Drain tray actions HERE, on the tk thread (safe Tcl context) -- never
        # from the WndProc, which runs during raw Windows message dispatch.
        if self.tray is not None:
            for action in self.tray.poll():
                if action == "show":
                    self._do_show()
                elif action == "balloon":
                    if self._last_balloon == "file":
                        self._open_received()
                elif action == "quit":
                    self._do_quit()
                    return  # window destroyed; stop the poll loop
        self.root.after(100, self._poll_events)

    # ---- ui ----
    def _build_ui(self):
        r = self.root
        r.title(f"{APP_NAME} Server")
        r.configure(bg=BG)
        r.geometry("440x500")
        r.resizable(False, False)
        try:
            base = getattr(sys, "_MEIPASS",
                           os.path.dirname(os.path.abspath(__file__)))
            ico = os.path.join(base, "JawnRemoteServer.ico")
            if os.path.exists(ico):
                r.iconbitmap(ico)
        except Exception:
            pass

        tk.Label(r, text=APP_NAME, bg=BG, fg=FG,
                 font=("Segoe UI Semibold", 22)).pack(pady=(16, 0))
        tk.Label(r, text="Phone mouse & keyboard", bg=BG, fg=MUTED,
                 font=("Segoe UI", 10)).pack()

        # NOTE: keep the "●  " prefix in sync with _set_status / the
        # _refresh_firewall guard below — otherwise the status never advances
        # past "Starting…" when the firewall is already configured at launch.
        self.status = tk.Label(r, text="●  Starting…", bg=BG, fg=MUTED,
                               font=("Segoe UI", 11, "bold"))
        self.status.pack(pady=(12, 8))
        self._status_font = tkfont.Font(root=r, font=self.status.cget("font"))

        card = tk.Frame(r, bg=CARD)
        card.pack(fill="x", padx=24, pady=6)
        # Two columns -- details left, browser-remote QR right (packed first so
        # it's never squeezed) -- keeps the window short enough for 1366x768
        # and 150%-scaled laptop screens.
        right = tk.Frame(card, bg=CARD)
        right.pack(side="right", anchor="n", padx=(0, 14), pady=12)
        left = tk.Frame(card, bg=CARD)
        left.pack(side="left", fill="both", expand=True)
        tk.Label(left, text="This PC", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(12, 0))
        tk.Label(left, text=self.name, bg=CARD, fg=FG,
                 font=("Segoe UI", 13)).pack(anchor="w", padx=16)
        tk.Label(left, text="Address", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(10, 0))
        self.addr_label = tk.Label(left, text=f"{self.ips[0]} : {PORT}", bg=CARD,
                                   fg=FG, font=("Consolas", 14))
        self.addr_label.pack(anchor="w", padx=16)
        # Always created (the addresses are re-checked); shown only when useful.
        self.also_label = tk.Label(left, text="also: " + ", ".join(self.ips[1:]),
                                   bg=CARD, fg=MUTED, font=("Consolas", 9),
                                   wraplength=230, justify="left")
        if len(self.ips) > 1:
            self.also_label.pack(anchor="w", padx=16)
        tk.Label(left, text="PIN", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(10, 0))
        tk.Label(left, text=self.pin, bg=CARD, fg=ACCENT,
                 font=("Consolas", 26, "bold")).pack(anchor="w", padx=16, pady=(0, 14))

        dim = (qr.SIZE + 2 * QR_QUIET) * QR_SCALE
        self.qr_cv = tk.Canvas(right, width=dim, height=dim, bg="white",
                               highlightthickness=0, bd=0)
        self.qr_cv.pack()
        # Two lines in both states and never wider than the QR, so toggling
        # the browser remote doesn't shift the columns.
        self.qr_caption = tk.Label(right, text="", bg=CARD, fg=MUTED,
                                   font=("Segoe UI", 8), wraplength=dim - 8,
                                   justify="center")
        self.qr_caption.pack(pady=(4, 0))

        self.fw_label = tk.Label(r, text="", bg=BG, fg=MUTED, font=("Segoe UI", 10))
        self.fw_label.pack(pady=(14, 2))
        self.fw_btn = tk.Button(r, text="Allow through firewall",
                                command=self._on_firewall, bg=ACCENT, fg="white",
                                activebackground="#3F73D6", relief="flat",
                                font=("Segoe UI", 10, "bold"), padx=14, pady=6,
                                cursor="hand2", borderwidth=0)
        self.fw_btn.pack()

        self.autostart_var = tk.BooleanVar(value=autostart_enabled())
        tk.Checkbutton(r, text="Start automatically when I sign in",
                       variable=self.autostart_var, command=self._on_autostart,
                       bg=BG, fg=MUTED, selectcolor=CARD, activebackground=BG,
                       activeforeground=FG, font=("Segoe UI", 10),
                       borderwidth=0, highlightthickness=0).pack(pady=(14, 0))

        btn_row = tk.Frame(r, bg=BG)
        btn_row.pack(pady=(12, 0))
        tk.Button(btn_row, text="Manage apps…", command=self._manage_apps,
                  bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
                  relief="flat", font=("Segoe UI", 10), padx=12, pady=5,
                  cursor="hand2", borderwidth=0).pack(side="left", padx=(0, 6))
        self.send_btn = tk.Button(
            btn_row, text="Send file to phone…", command=self._send_file,
            bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
            relief="flat", font=("Segoe UI", 10), padx=12, pady=5,
            cursor="hand2", borderwidth=0)
        self.send_btn.pack(side="left")
        tk.Button(btn_row, text="Received files…",
                  command=self._open_received,
                  bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
                  relief="flat", font=("Segoe UI", 10), padx=12, pady=5,
                  cursor="hand2", borderwidth=0).pack(side="left", padx=(6, 0))

        self.web_var = tk.BooleanVar(value=not os.path.exists(self._web_off_flag))
        tk.Checkbutton(r, text="Allow browser remote (control from any device, no app)",
                       variable=self.web_var, command=self._on_web_toggle,
                       bg=BG, fg=MUTED, selectcolor=CARD, activebackground=BG,
                       activeforeground=FG, font=("Segoe UI", 9),
                       borderwidth=0, highlightthickness=0).pack(pady=(14, 0))
        web_row = tk.Frame(r, bg=BG)
        web_row.pack(pady=(2, 0))
        self.url_label = tk.Label(web_row, text=f"http://{self.ips[0]}:{PORT}/",
                                  bg=BG, fg=ACCENT, font=("Consolas", 10),
                                  cursor="hand2")
        self.url_label.pack()
        self.url_label.bind("<Button-1>", lambda e: self._open_browser())

        self.footer = tk.Label(r, text="Closing (X) keeps it running in the tray · "
                                       "right-click the icon to quit",
                               bg=BG, fg=MUTED, font=("Segoe UI", 8),
                               justify="center")
        self.footer.pack(side="bottom", pady=8)

        self._apply_web_state()
        self._fit_window()

    def _fit_window(self):
        """Size the window to fit all controls so the action buttons are never
        clipped (content varies with firewall state and the IP addresses)."""
        self.root.update_idletasks()
        w = max(460, self.root.winfo_reqwidth())
        self.root.geometry(f"{w}x{self.root.winfo_reqheight()}")

    def _manage_apps(self):
        # One manager at a time: a second one's stale list would overwrite the
        # first one's edits when it saves.
        m = self._apps_mgr
        if m is not None and m.win.winfo_exists():
            m.win.deiconify()
            m.win.lift()
            try:
                m.win.focus_force()
            except Exception:
                pass
            return
        self._apps_mgr = AppsManager(self.root)

    def _send_file(self):
        if self.server is None:
            return
        if self._sending:
            self._set_status("Already sending a file — wait for it to finish", AMBER)
            return
        if self.server.latest_client() is None:
            self._set_status("Open the JawnRemote app on your phone first", AMBER)
            return
        path = filedialog.askopenfilename(title="Send a file to your phone")
        if not path:
            return
        # Look the phone up again: it may have reconnected (new socket) while
        # the dialog was open, and the old connection is dead.
        client = self.server.latest_client()
        if client is None:
            self._set_status("Open the JawnRemote app on your phone first", AMBER)
            return
        name = _short(os.path.basename(path), 20)
        self._sending = True
        self.send_btn.configure(state="disabled")
        self._set_status(f"Sending {name}…", ACCENT)

        def prog(done, total):
            pct = int(done * 100 / total) if total else 0
            self.root.after(0, lambda: self._set_status(
                f"Sending {name}…  {pct}%", ACCENT))

        def finish(ok, err):
            if ok:
                self._set_status(f"Sent {name} to your phone ✓", GREEN)
            else:
                self._set_status(f"Couldn't send {name}" + (f": {err}" if err else ""),
                                 AMBER)
            # The phone dropping is often WHY a send failed: keep the result up
            # instead of letting the paired "disconnected" replace it at once.
            self._hold_status()
            self._sending = False
            self.send_btn.configure(state="normal")

        def work():
            try:
                ok, err = client.push_file(path, progress=prog)
            except Exception:
                ok, err = False, None
            self.root.after(0, lambda: finish(ok, err))

        threading.Thread(target=work, daemon=True).start()

    def _open_received(self):
        """Open the folder where files the phone sends us land (Explorer)."""
        folder = fx.received_dir()
        try:
            os.startfile(folder)
        except OSError:
            self._set_status("Couldn't open the files folder", "#E8A33D")

    def _on_web_toggle(self):
        on = self.web_var.get()
        if self.server is not None:
            self.server.web_enabled = on
        try:
            if on and os.path.exists(self._web_off_flag):
                os.remove(self._web_off_flag)
            elif not on:
                open(self._web_off_flag, "w").close()
        except OSError:
            pass
        self._apply_web_state()

    def _apply_web_state(self):
        """Offer the browser URL/QR only while the browser remote is allowed
        (the QR slot keeps its size, so the window doesn't jump)."""
        if self.web_var.get():
            self.url_label.configure(fg=ACCENT, cursor="hand2")
            self.qr_caption.configure(text="Scan to open the\nbrowser remote")
        else:
            self.url_label.configure(fg=MUTED, cursor="")
            self.qr_caption.configure(text="Turn on browser remote\nto use this")
        self._draw_qr()

    def _open_browser(self):
        if not self.web_var.get():
            return
        try:
            webbrowser.open(f"http://{self.ips[0]}:{PORT}/")
        except Exception:
            pass

    def _draw_qr(self):
        """(Re)draw the scannable QR of the browser-remote URL (pure-stdlib
        generator), or a placeholder while the browser remote is off."""
        cv = self.qr_cv
        cv.delete("all")
        dim = int(cv.cget("width"))
        if not self.web_var.get():
            cv.configure(bg=CARD)
            cv.create_rectangle(0, 0, dim - 1, dim - 1, outline="#2A3340")
            cv.create_text(dim // 2, dim // 2, text="Browser remote\nis off",
                           fill=MUTED, font=("Segoe UI", 9), justify="center")
            return
        cv.configure(bg="white")
        mods = qr.matrix(f"http://{self.ips[0]}:{PORT}/#{self.pin}")
        n = len(mods)
        for rr in range(n):
            for cc in range(n):
                if mods[rr][cc]:
                    x = (cc + QR_QUIET) * QR_SCALE
                    y = (rr + QR_QUIET) * QR_SCALE
                    cv.create_rectangle(x, y, x + QR_SCALE, y + QR_SCALE,
                                        fill="black", outline="")

    # ---- LAN addresses (Wi-Fi may come up after us; networks change) ----
    def _check_ips(self):
        """Re-read the addresses off the tk thread (now, then every 15 s);
        _poll_events applies the result."""
        if self._ip_job is not None:
            self.root.after_cancel(self._ip_job)

        def work():
            try:
                self.events.put(("ips", srv.get_lan_ips()))
            except Exception:
                pass

        threading.Thread(target=work, daemon=True).start()
        self._ip_job = self.root.after(15000, self._check_ips)

    def _update_ips(self, ips):
        if not ips or ips == self.ips:
            return
        old0 = self.ips[0]
        self.ips = ips
        self.addr_label.configure(text=f"{ips[0]} : {PORT}")
        self.url_label.configure(text=f"http://{ips[0]}:{PORT}/")
        if len(ips) > 1:
            self.also_label.configure(text="also: " + ", ".join(ips[1:]))
            self.also_label.pack(after=self.addr_label, anchor="w", padx=16)
        else:
            self.also_label.pack_forget()
        if ips[0] != old0:
            self._draw_qr()
        self._fit_window()

    # ---- status line ----
    def _set_status(self, text, color):
        if self._server_error and text != self._server_error:
            return      # no server running: keep saying why
        self.status.configure(text=self._fit_status("●  " + text), fg=color)

    def _fit_status(self, text):
        """Backstop for long names: cut more out of the middle -- of the
        already shortened name, if any -- so both the leading dot and the end
        of the message stay visible (the label is centered, so it would clip
        both ends)."""
        avail = self.root.winfo_width() - 16
        if "\n" in text or avail < 100 or self._status_font.measure(text) <= avail:
            return text
        c = text.find("…")
        head, tail = (text[:c], text[c + 1:]) if c > 0 else \
            (text[:len(text) // 2], text[len(text) // 2:])
        cut_head = True
        while len(head) > 4 and tail:
            if cut_head:
                head = head[:-1]
            else:
                tail = tail[1:]
            cut_head = not cut_head
            t = head + "…" + tail
            if self._status_font.measure(t) <= avail:
                return t
        return text

    def _hold_status(self, secs=8):
        """Keep the status just set (a transfer result) on screen for `secs`
        before connect/disconnect updates may replace it."""
        self._status_hold = time.monotonic() + secs

    def _show_conn_status(self):
        if self._server_error:
            return
        left = self._status_hold - time.monotonic()
        if left > 0:
            if self._status_retry is None:
                def again():
                    self._status_retry = None
                    self._show_conn_status()
                self._status_retry = self.root.after(int(left * 1000) + 50, again)
            return
        if self._sessions:
            n = len(self._sessions)
            extra = f"  (+{n - 1} more)" if n > 1 else ""
            self._set_status(f"Connected:  {_short(self._sessions[-1], 24)}{extra}",
                             GREEN)
        else:
            self._set_status("Ready — waiting for your phone", MUTED)

    def _refresh_firewall(self):
        self.fw_btn.configure(state="normal")
        if firewall_ok():
            self.fw_label.configure(text="✓ Firewall is configured", fg=GREEN)
            self.fw_btn.pack_forget()
        else:
            self.fw_label.configure(
                text="Firewall not set up — phone can't connect yet", fg=AMBER)
            self.fw_btn.pack(after=self.fw_label)
        # Only advance past "Starting…" -- never clobber "Connected"/"Sending".
        if self.status.cget("text").startswith("●  Starting"):
            self._show_conn_status()
        self._fit_window()

    def _on_firewall(self):
        if not add_firewall_rules():
            self.fw_label.configure(
                text="Firewall change was cancelled — click to try again", fg=AMBER)
            return
        self.fw_label.configure(text="Applying firewall rules…", fg=MUTED)
        self.fw_btn.configure(state="disabled")
        self._fw_tries = 0
        self.root.after(1500, self._poll_firewall)

    def _poll_firewall(self):
        # Re-check while the elevated command runs (up to ~15 s on a slow PC).
        self._fw_tries += 1
        if firewall_ok() or self._fw_tries >= 10:
            self._refresh_firewall()
        else:
            self.root.after(1500, self._poll_firewall)

    def _on_autostart(self):
        want = self.autostart_var.get()
        if not set_autostart(want):
            self.autostart_var.set(not want)
            self._set_status("Couldn't change the startup setting", AMBER)

    # ---- tray (close-to-tray instead of full shutdown) ----
    def _setup_tray(self):
        if tray_win is None:
            return
        try:
            self.root.update_idletasks()   # ensure the OS window exists
            base = getattr(sys, "_MEIPASS",
                           os.path.dirname(os.path.abspath(__file__)))
            ico = os.path.join(base, "JawnRemoteServer.ico")
            hwnd = tray_win.host_hwnd(self.root)
            self.tray = tray_win.TrayIcon(
                hwnd, ico, f"{APP_NAME} — phone mouse & keyboard")
            # Tray clicks are picked up by _poll_events (see self.tray.poll()).
            # With a tray icon present, the X button hides instead of quitting.
            self.root.protocol("WM_DELETE_WINDOW", self._hide_to_tray)
        except Exception:
            # Tray is optional: if anything fails, leave the normal X behavior
            # (don't trap the window with no way to bring it back).
            self.tray = None

    def _hide_to_tray(self, hint=True):
        if self.tray and not self.tray.added:
            self.tray.readd()
        if not (self.tray and self.tray.added):
            # No icon to bring it back with (taskbar not up yet / Explorer
            # restarting): minimize instead so the window stays reachable.
            self.root.iconify()
            return
        self.root.withdraw()
        if hint and not os.path.exists(self._tray_hint):
            self.tray.show_balloon(
                APP_NAME,
                "Still running here. Click the icon to reopen, "
                "or right-click it to quit.")
            self._last_balloon = "hint"
            try:
                open(self._tray_hint, "w").close()
            except Exception:
                pass

    def _do_show(self):
        self.root.deiconify()
        self.root.lift()
        try:
            self.root.focus_force()
        except Exception:
            pass
        self._check_ips()

    def _do_quit(self):
        try:
            if self.tray:
                self.tray.remove()
        except Exception:
            pass
        try:
            self.server.shutdown()
            self.server.server_close()
        except Exception:
            pass
        self.root.destroy()


# Named colors offered in the app editor -> RRGGBB.
APP_COLORS = {
    "Red": "FF0000", "Pink": "E50914", "Green": "1DB954", "Mint": "1CE783",
    "Sky": "00A8E1", "Cyan": "17B2E7", "Blue": "0046FF", "Navy": "113CCF",
    "Purple": "9146FF", "Orange": "FF8800", "Grey": "8A94A6",
}


def _flat_button(parent, text, cmd, primary=False):
    return tk.Button(
        parent, text=text, command=cmd,
        bg=(ACCENT if primary else CARD), fg="white" if primary else FG,
        activebackground=("#3F73D6" if primary else "#1F2733"),
        activeforeground="white" if primary else FG, relief="flat",
        font=("Segoe UI", 10, "bold") if primary else ("Segoe UI", 10),
        padx=12, pady=5, cursor="hand2", borderwidth=0)


def _dark_option(parent, var, values):
    om = tk.OptionMenu(parent, var, *values)
    om.config(bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
              relief="flat", highlightthickness=0, borderwidth=0,
              font=("Segoe UI", 10))
    try:
        om["menu"].config(bg=CARD, fg=FG, activebackground=ACCENT,
                          activeforeground="white", borderwidth=0)
    except Exception:
        pass
    return om


class AppsManager:
    """Window to add/edit/remove/reorder the phone's quick-launch apps."""

    def __init__(self, parent):
        self.apps = appstore.load_apps()
        self.win = tk.Toplevel(parent)
        self.win.title("Manage apps")
        self.win.configure(bg=BG)
        self.win.geometry("470x470")
        self.win.transient(parent)
        try:
            self.win.grab_set()
        except Exception:
            pass

        tk.Label(self.win, text="Quick-launch apps", bg=BG, fg=FG,
                 font=("Segoe UI Semibold", 14)).pack(anchor="w", padx=16, pady=(14, 0))
        tk.Label(self.win,
                 text="These show on your phone's Apps screen. A target can be a "
                      "website, a spotify:/steam: link, or an app like vlc.exe.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 9), wraplength=430,
                 justify="left").pack(anchor="w", padx=16, pady=(2, 10))

        body = tk.Frame(self.win, bg=BG)
        body.pack(fill="both", expand=True, padx=16)
        self.listbox = tk.Listbox(body, bg=CARD, fg=FG, selectbackground=ACCENT,
                                  selectforeground="white", borderwidth=0,
                                  highlightthickness=0, activestyle="none",
                                  font=("Segoe UI", 11))
        self.listbox.pack(side="left", fill="both", expand=True)
        self.listbox.bind("<Double-Button-1>", lambda e: self._edit())
        sb = tk.Scrollbar(body, command=self.listbox.yview)
        sb.pack(side="right", fill="y")
        self.listbox.config(yscrollcommand=sb.set)

        btns = tk.Frame(self.win, bg=BG)
        btns.pack(fill="x", padx=16, pady=12)
        for text, cmd in (("Add", self._add), ("Edit", self._edit),
                          ("Remove", self._remove),
                          ("Up", lambda: self._move(-1)),
                          ("Down", lambda: self._move(1))):
            _flat_button(btns, text, cmd).pack(side="left", padx=(0, 6))
        _flat_button(btns, "Close", self.win.destroy, primary=True).pack(side="right")

        self._refresh()

    def _refresh(self, select=None):
        self.listbox.delete(0, tk.END)
        for a in self.apps:
            self.listbox.insert(tk.END, f"  {a['name']}   —   {a['target']}")
        if select is not None and 0 <= select < len(self.apps):
            self.listbox.selection_clear(0, tk.END)
            self.listbox.selection_set(select)
            self.listbox.activate(select)

    def _selected(self):
        sel = self.listbox.curselection()
        return sel[0] if sel else None

    def _save(self, select=None):
        self.apps = appstore.save_apps(self.apps)
        self._refresh(select)

    def _add(self):
        AppEditor(self.win, None, self._on_add)

    def _on_add(self, entry):
        self.apps.append(entry)
        self._save(len(self.apps) - 1)

    def _edit(self):
        i = self._selected()
        if i is None:
            return
        AppEditor(self.win, dict(self.apps[i]), lambda e: self._on_edit(i, e))

    def _on_edit(self, i, entry):
        self.apps[i] = entry
        self._save(i)

    def _remove(self):
        i = self._selected()
        if i is None:
            return
        if not messagebox.askyesno("Remove app", f"Remove '{self.apps[i]['name']}'?",
                                   parent=self.win):
            return
        del self.apps[i]
        self._save(min(i, len(self.apps) - 1) if self.apps else None)

    def _move(self, delta):
        i = self._selected()
        if i is None:
            return
        j = i + delta
        if 0 <= j < len(self.apps):
            self.apps[i], self.apps[j] = self.apps[j], self.apps[i]
            self._save(j)


class AppEditor:
    """Modal add/edit dialog for a single app entry."""

    def __init__(self, parent, entry, on_save):
        self.parent = parent
        self.on_save = on_save
        self.win = tk.Toplevel(parent)
        self.win.title("Edit app" if entry else "Add app")
        self.win.configure(bg=BG)
        self.win.geometry("370x310")
        self.win.transient(parent)
        self.win.protocol("WM_DELETE_WINDOW", self._close)
        self.win.bind("<Return>", lambda e: self._save())
        self.win.bind("<Escape>", lambda e: self._close())
        try:
            self.win.grab_set()
        except Exception:
            pass

        entry = entry or {"name": "", "target": "", "icon": "app", "color": "4F8CFF"}

        def field(label, value):
            tk.Label(self.win, text=label, bg=BG, fg=MUTED,
                     font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(10, 0))
            e = tk.Entry(self.win, bg=CARD, fg=FG, insertbackground=FG,
                         relief="flat", font=("Segoe UI", 11))
            e.insert(0, value)
            e.pack(fill="x", padx=16, ipady=4)
            return e

        self.name = field("Name", entry["name"])
        self.target = field("Target (URL, protocol, or app.exe)", entry["target"])

        row = tk.Frame(self.win, bg=BG)
        row.pack(fill="x", padx=16, pady=(10, 0))
        tk.Label(row, text="Icon", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w")
        tk.Label(row, text="Color", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).grid(row=0, column=1, sticky="w", padx=(12, 0))
        self.icon_var = tk.StringVar(
            value=entry["icon"] if entry["icon"] in appstore.ICON_KEYWORDS else "app")
        _dark_option(row, self.icon_var, appstore.ICON_KEYWORDS).grid(
            row=1, column=0, sticky="ew")
        cur = next((n for n, h in APP_COLORS.items()
                    if h == str(entry["color"]).upper()), "Blue")
        self.color_var = tk.StringVar(value=cur)
        _dark_option(row, self.color_var, list(APP_COLORS.keys())).grid(
            row=1, column=1, sticky="ew", padx=(12, 0))
        row.columnconfigure(0, weight=1)
        row.columnconfigure(1, weight=1)

        actions = tk.Frame(self.win, bg=BG)
        actions.pack(fill="x", padx=16, pady=16, side="bottom")
        _flat_button(actions, "Cancel", self._close).pack(side="right", padx=(6, 0))
        _flat_button(actions, "Save", self._save, primary=True).pack(side="right")
        self.hint = tk.Label(self.win, text="", bg=BG, fg=AMBER,
                             font=("Segoe UI", 9))
        self.hint.pack(side="bottom")          # just above the buttons
        self.name.focus_set()

    def _close(self):
        self.win.destroy()
        # Tk has one grab: hand it back to the manager window we came from.
        try:
            if self.parent.winfo_exists():
                self.parent.grab_set()
        except tk.TclError:
            pass

    def _save(self):
        name = self.name.get().strip()
        target = self.target.get().strip()
        if not name or not target:
            self.win.bell()
            self.hint.configure(text="Name and target are both required")
            (self.target if name else self.name).focus_set()
            return
        self.on_save({
            "name": name, "target": target,
            "icon": self.icon_var.get(),
            "color": APP_COLORS.get(self.color_var.get(), "4F8CFF"),
        })
        self._close()


def main():
    if _claim_single_instance():
        return      # already running -- that copy was asked to show itself
    hidden = AUTOSTART_ARG in sys.argv[1:]
    root = tk.Tk()
    if hidden:
        root.attributes("-alpha", 0.0)      # no window flash at sign-in
    app = App(root)
    if hidden:
        # Withdraw only now: the tray needed the mapped window. With no tray,
        # or no server (keep its "Can't start" visible), it shows as usual.
        if app.tray is not None and app.server is not None:
            app._hide_to_tray(hint=False)
        root.attributes("-alpha", 1.0)
    root.mainloop()


if __name__ == "__main__":
    main()
