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
import ctypes
import winreg

import tkinter as tk

import server as srv

APP_NAME = "JawnRemote"
PORT = srv.DEFAULT_PORT
FW_RULE = "JawnRemote"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
CREATE_NO_WINDOW = 0x08000000

BG = "#0E1116"
CARD = "#161C24"
FG = "#FFFFFF"
MUTED = "#8A94A6"
ACCENT = "#4F8CFF"
GREEN = "#3DDC84"


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
    try:
        out = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={FW_RULE}"],
            capture_output=True, text=True, creationflags=CREATE_NO_WINDOW)
        return "No rules match" not in out.stdout
    except Exception:
        return False


def add_firewall_rules():
    """Add inbound TCP+UDP allow rules (self-elevates with one UAC prompt)."""
    parts = [
        f'netsh advfirewall firewall delete rule name="{FW_RULE}"',
        f'netsh advfirewall firewall delete rule name="{FW_RULE} (discovery)"',
        f'netsh advfirewall firewall add rule name="{FW_RULE}" dir=in '
        f'action=allow protocol=TCP localport={PORT} profile=any',
        f'netsh advfirewall firewall add rule name="{FW_RULE} (discovery)" dir=in '
        f'action=allow protocol=UDP localport={PORT} profile=any',
    ]
    cmd = " & ".join(parts)
    ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd.exe", f"/c {cmd}", None, 0)


def autostart_enabled():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP_NAME)
        return True
    except OSError:
        return False


def set_autostart(enable):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0,
                            winreg.KEY_SET_VALUE) as k:
            if enable:
                winreg.SetValueEx(k, APP_NAME, 0, winreg.REG_SZ, exe_command())
            else:
                try:
                    winreg.DeleteValue(k, APP_NAME)
                except OSError:
                    pass
    except OSError:
        pass


class App:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.name = socket.gethostname()
        self.ips = srv.get_lan_ips()

        srv.PIN_FILE = os.path.join(data_dir(), "pin.txt")
        self.pin = srv.load_or_create_pin(None)

        self._build_ui()
        self._start_server()
        self._poll_events()
        self._refresh_firewall()

    # ---- server ----
    def _start_server(self):
        self.server = srv.build_server(PORT, "0.0.0.0", self.pin, True,
                                       on_event=self._on_event)
        srv.start_discovery(PORT, self.name)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def _on_event(self, event, info=""):
        self.events.put((event, info))

    def _poll_events(self):
        try:
            while True:
                event, info = self.events.get_nowait()
                if event == "connected":
                    self._set_status(f"Connected:  {info}", GREEN)
                elif event == "disconnected":
                    self._set_status("Ready — waiting for your phone", MUTED)
        except queue.Empty:
            pass
        self.root.after(200, self._poll_events)

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
                 font=("Segoe UI Semibold", 22)).pack(pady=(22, 0))
        tk.Label(r, text="Phone mouse & keyboard", bg=BG, fg=MUTED,
                 font=("Segoe UI", 10)).pack()

        self.status = tk.Label(r, text="Starting…", bg=BG, fg=MUTED,
                               font=("Segoe UI", 11, "bold"))
        self.status.pack(pady=(16, 8))

        card = tk.Frame(r, bg=CARD)
        card.pack(fill="x", padx=24, pady=6)
        tk.Label(card, text="This PC", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(12, 0))
        tk.Label(card, text=self.name, bg=CARD, fg=FG,
                 font=("Segoe UI", 13)).pack(anchor="w", padx=16)
        tk.Label(card, text="Address", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(10, 0))
        tk.Label(card, text=f"{self.ips[0]} : {PORT}", bg=CARD, fg=FG,
                 font=("Consolas", 14)).pack(anchor="w", padx=16)
        if len(self.ips) > 1:
            tk.Label(card, text="also: " + ", ".join(self.ips[1:]), bg=CARD,
                     fg=MUTED, font=("Consolas", 9)).pack(anchor="w", padx=16)
        tk.Label(card, text="PIN", bg=CARD, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(10, 0))
        tk.Label(card, text=self.pin, bg=CARD, fg=ACCENT,
                 font=("Consolas", 26, "bold")).pack(anchor="w", padx=16, pady=(0, 14))

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

        tk.Label(r, text="Keep this open to use your phone as a mouse/keyboard.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(side="bottom", pady=10)

    def _set_status(self, text, color):
        self.status.configure(text="●  " + text, fg=color)

    def _refresh_firewall(self):
        if firewall_ok():
            self.fw_label.configure(text="✓ Firewall is configured", fg=GREEN)
            self.fw_btn.pack_forget()
            if self.status.cget("text").startswith("●  Starting"):
                self._set_status("Ready — waiting for your phone", MUTED)
        else:
            self.fw_label.configure(
                text="Firewall not set up — phone can't connect yet", fg="#E8A33D")
            self.fw_btn.pack()
            self._set_status("Ready — waiting for your phone", MUTED)

    def _on_firewall(self):
        add_firewall_rules()
        # re-check a few times while the elevated command runs
        self.root.after(1500, self._refresh_firewall)
        self.root.after(4000, self._refresh_firewall)

    def _on_autostart(self):
        set_autostart(self.autostart_var.get())


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
