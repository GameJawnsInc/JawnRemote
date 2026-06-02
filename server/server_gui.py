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
import traceback
import ctypes
import winreg

import tkinter as tk
from tkinter import filedialog

import server as srv
import apps_store as appstore

try:
    import tray_win
except Exception:
    tray_win = None

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
    """Add inbound TCP+UDP allow rules (self-elevates with one UAC prompt).

    Scoped to remoteip=localsubnet so only devices on your own network can
    reach the server -- the open port is invisible to the internet. profile=any
    is kept so it works even when Windows marks your Wi-Fi as 'Public'.
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
        self._build_ui()
        self._start_server()
        self._poll_events()
        self._refresh_firewall()
        self._setup_tray()

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
                elif event == "file_in":
                    self._set_status(f"Received {info} ✓", GREEN)
        except queue.Empty:
            pass
        # Drain tray actions HERE, on the tk thread (safe Tcl context) -- never
        # from the WndProc, which runs during raw Windows message dispatch.
        if self.tray is not None:
            for action in self.tray.poll():
                if action == "show":
                    self._do_show()
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

        btn_row = tk.Frame(r, bg=BG)
        btn_row.pack(pady=(12, 0))
        tk.Button(btn_row, text="Manage apps…", command=self._manage_apps,
                  bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
                  relief="flat", font=("Segoe UI", 10), padx=12, pady=5,
                  cursor="hand2", borderwidth=0).pack(side="left", padx=(0, 6))
        tk.Button(btn_row, text="Send file to phone…", command=self._send_file,
                  bg=CARD, fg=FG, activebackground="#1F2733", activeforeground=FG,
                  relief="flat", font=("Segoe UI", 10), padx=12, pady=5,
                  cursor="hand2", borderwidth=0).pack(side="left")

        tk.Label(r, text="Keep this open to use your phone as a mouse/keyboard.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(side="bottom", pady=10)

    def _manage_apps(self):
        AppsManager(self.root)

    def _send_file(self):
        client = self.server.latest_client()
        if client is None:
            self._set_status("Connect your phone first, then try again", "#E8A33D")
            return
        path = filedialog.askopenfilename(title="Send a file to your phone")
        if not path:
            return
        name = os.path.basename(path)
        self._set_status(f"Sending {name}…", ACCENT)

        def prog(done, total):
            pct = int(done * 100 / total) if total else 0
            self.root.after(0, lambda: self._set_status(
                f"Sending {name}…  {pct}%", ACCENT))

        def work():
            try:
                ok = client.push_file(path, progress=prog)
            except Exception:
                ok = False
            self.root.after(0, lambda: self._set_status(
                f"Sent {name} to your phone ✓" if ok
                else f"Couldn't send {name} (is the app open?)",
                GREEN if ok else "#E8A33D"))

        threading.Thread(target=work, daemon=True).start()

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

    def _hide_to_tray(self):
        self.root.withdraw()
        if self.tray and not os.path.exists(self._tray_hint):
            self.tray.show_balloon(
                APP_NAME,
                "Still running here. Click the icon to reopen, "
                "or right-click it to quit.")
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
        self.on_save = on_save
        self.win = tk.Toplevel(parent)
        self.win.title("Edit app" if entry else "Add app")
        self.win.configure(bg=BG)
        self.win.geometry("370x310")
        self.win.transient(parent)
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
        _flat_button(actions, "Cancel", self.win.destroy).pack(side="right", padx=(6, 0))
        _flat_button(actions, "Save", self._save, primary=True).pack(side="right")
        self.name.focus_set()

    def _save(self):
        name = self.name.get().strip()
        target = self.target.get().strip()
        if name and target:
            self.on_save({
                "name": name, "target": target,
                "icon": self.icon_var.get(),
                "color": APP_COLORS.get(self.color_var.get(), "4F8CFF"),
            })
        self.win.destroy()


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
