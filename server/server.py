"""
JawnRemote server -- turns this PC into a mouse/keyboard receiver for the phone app.

Protocol: newline-delimited JSON over TCP. The phone connects, sends a "hello"
with the PIN, then streams input events. A UDP responder answers discovery
broadcasts so the app can find this PC automatically.

Zero external dependencies -- just run with Python 3.

  py server.py                 # default port 8770, auto PIN
  py server.py --port 8770     # choose port
  py server.py --pin 1234      # fixed PIN
  py server.py --no-auth       # no PIN (testing only)
"""
import argparse
import base64
import ipaddress
import itertools
import json
import os
import secrets
import socket
import socketserver
import sys
import threading
import time

import input_win as inp
import power_win as pwr
import launch_win as lch
import apps_store as appstore
import netinfo_win as netinfo
import clipboard_win as clip
import screen_win
import filexfer as fx
import web_remote

APP = "JawnRemote"
VERSION = 1
DEFAULT_PORT = 8770
PIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pin.txt")

# Brute-force protection: temporarily refuse an IP after too many bad PINs.
MAX_PIN_FAILS = 5
LOCKOUT_SECONDS = 60

_print_lock = threading.Lock()


def log(*a):
    with _print_lock:
        print(*a, flush=True)


def get_lan_ips():
    """Best-effort list of this machine's LAN IPv4 addresses, primary first."""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))  # no packets sent; just picks the route
        ips.append(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    return ips or ["127.0.0.1"]


def is_lan_ip(ip):
    """True if ip is a private / loopback / link-local address (a LAN peer)."""
    try:
        return ipaddress.ip_address(ip).is_private
    except ValueError:
        return False


def load_or_create_pin(override=None):
    if override:
        return str(override)
    try:
        with open(PIN_FILE, "r", encoding="utf-8") as f:
            pin = f.read().strip()
        if pin.isdigit() and 4 <= len(pin) <= 8:
            return pin
    except OSError:
        pass
    pin = f"{secrets.randbelow(10000):04d}"
    try:
        with open(PIN_FILE, "w", encoding="utf-8") as f:
            f.write(pin)
    except OSError:
        pass
    return pin


class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        super().setup()
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        self.authed = not self.server.require_auth
        self._who = None
        self._incoming = None           # in-progress inbound file (phone -> PC)
        self._wlock = threading.Lock()  # serialize writes (read-loop vs GUI push)
        self._send_cv = threading.Condition()  # outbound push ack signaling
        self._send_acked = 0
        self._send_stop = False
        self._send_done = None

    def send(self, obj):
        data = (json.dumps(obj) + "\n").encode("utf-8")
        with self._wlock:
            try:
                self.wfile.write(data)
                self.wfile.flush()
            except OSError:
                pass

    def handle(self):
        peer = self.client_address[0]
        # Defense in depth: even if the firewall is mis-scoped or the port is
        # forwarded, only accept LAN peers (this is a local-network remote).
        if getattr(self.server, "lan_only", True) and not is_lan_ip(peer):
            log(f"[!] refused non-LAN connection from {peer}")
            return
        first = self.rfile.readline()
        if not first:
            return
        if web_remote.looks_like_http(first):
            # A browser hit the same port -> serve the no-install web remote.
            try:
                web_remote.serve(self, first, log=log)
            except (ConnectionError, OSError):
                pass
            return
        log(f"[+] {peer} connected")
        try:
            for raw in itertools.chain([first], self.rfile):
                line = raw.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if isinstance(msg, dict):
                    resp = self.dispatch(msg)
                    if resp is not None:
                        self.send(resp)
        except (ConnectionError, OSError):
            pass
        finally:
            self.server.unregister_client(self)
            log(f"[-] {peer} disconnected")
            if self._who:
                self.server.on_event("disconnected", self._who)

    def _auth_locked(self, peer):
        with self.server.auth_lock:
            return time.time() < self.server.bans.get(peer, 0)

    def _record_auth_fail(self, peer):
        with self.server.auth_lock:
            n = self.server.fails.get(peer, 0) + 1
            self.server.fails[peer] = n
            if n >= MAX_PIN_FAILS:
                self.server.bans[peer] = time.time() + LOCKOUT_SECONDS
                self.server.fails[peer] = 0
                log(f"[!] locked out {peer} for {LOCKOUT_SECONDS}s "
                    f"after {MAX_PIN_FAILS} bad PINs")

    def _record_auth_ok(self, peer):
        with self.server.auth_lock:
            self.server.fails.pop(peer, None)
            self.server.bans.pop(peer, None)

    def dispatch(self, msg):
        t = msg.get("t")
        if t == "hello":
            peer = self.client_address[0]
            if self._auth_locked(peer):
                log(f"    hello from {peer}: REFUSED (locked out)")
                return {"t": "welcome", "ok": False, "err": "locked"}
            ok = (not self.server.require_auth) or \
                 (str(msg.get("pin", "")) == self.server.pin)
            who = msg.get("name", "device")
            if not ok:
                self._record_auth_fail(peer)
                log(f"    hello from {who!r} @ {peer}: BAD PIN")
                return {"t": "welcome", "ok": False, "err": "bad_pin"}
            self._record_auth_ok(peer)
            self.authed = True
            self._who = who
            self.server.register_client(self)
            log(f"    hello from {who!r} @ {peer}: OK")
            self.server.on_event("connected", who)
            return {"t": "welcome", "ok": True, "server": self.server.server_name,
                    "app": APP, "v": VERSION,
                    "mac": getattr(self.server, "mac", "")}
        if t == "ping":
            return {"t": "pong"}
        if not self.authed:
            return {"t": "error", "err": "unauthorized"}
        if t == "getapps":
            return {"t": "apps", "apps": appstore.load_apps()}
        if t == "clipget":
            return {"t": "clip", "s": clip.get_text()}
        if t == "shot":
            try:
                png, w, h = screen_win.capture_png()
                return {"t": "shot", "w": w, "h": h,
                        "img": base64.b64encode(png).decode("ascii")}
            except Exception as e:
                log(f"    shot error: {e!r}")
                return {"t": "shot", "err": True}
        if t in ("filebeg", "filedat", "fileend", "fileabort",
                 "fileack", "filedone"):
            return self.do_file(t, msg)
        try:
            self.do_input(t, msg)
        except Exception as e:  # never let one bad event kill the stream
            log(f"    input error on {t!r}: {e!r}")
        return None

    def do_input(self, t, msg):
        if t == "m":
            inp.move(int(msg.get("x", 0)), int(msg.get("y", 0)))
        elif t == "click":
            inp.click(msg.get("b", "left"))
        elif t == "down":
            inp.mouse_down(msg.get("b", "left"))
        elif t == "up":
            inp.mouse_up(msg.get("b", "left"))
        elif t == "scroll":
            inp.scroll(dy=int(msg.get("y", 0)), dx=int(msg.get("x", 0)))
        elif t == "text":
            s = msg.get("s", "")
            if isinstance(s, str) and s:
                inp.type_text(s)
        elif t == "key":
            k = msg.get("k")
            if k:
                inp.key(k, msg.get("m") or [])
        elif t == "power":
            action = msg.get("action", "")
            if pwr.power(action):
                log(f"    power: {action}")
        elif t == "launch":
            target = msg.get("target", "")
            if lch.launch(target):
                log(f"    launch: {target}")
        elif t == "clipset":
            s = msg.get("s", "")
            if isinstance(s, str) and clip.set_text(s):
                log("    clipboard set from phone")

    def do_file(self, t, msg):
        """Handle one file-transfer frame (either direction). Returns a reply
        dict to send back, or None. Inbound frames (filebeg/dat/end) write the
        file to disk; fileack/filedone advance an outbound GUI->phone push."""
        fid = msg.get("id")
        if t == "filebeg":
            if self._incoming:
                self._incoming.abort()
                self._incoming = None
            try:
                self._incoming = fx.Incoming(msg)
            except (OSError, ValueError) as e:
                return {"t": "filedone", "id": fid, "ok": False, "err": str(e)}
            return {"t": "fileack", "id": fid, "i": -1}
        if t == "filedat":
            inc = self._incoming
            if not inc or inc.id != fid:
                return {"t": "filedone", "id": fid, "ok": False, "err": "no transfer"}
            try:
                i = int(msg.get("i", -1))
                inc.write_chunk(i, msg.get("b", ""))
                return {"t": "fileack", "id": fid, "i": i}
            except (OSError, ValueError) as e:
                inc.abort()
                self._incoming = None
                return {"t": "filedone", "id": fid, "ok": False, "err": str(e)}
        if t == "fileend":
            inc = self._incoming
            if not inc or inc.id != fid:
                return {"t": "filedone", "id": fid, "ok": False, "err": "no transfer"}
            try:
                path = inc.finish(msg.get("sha"))
                self._incoming = None
                log(f"    received file -> {path}")
                self.server.on_event("file_in", os.path.basename(path))
                return {"t": "filedone", "id": fid, "ok": True, "path": path}
            except (OSError, ValueError) as e:
                inc.abort()
                self._incoming = None
                return {"t": "filedone", "id": fid, "ok": False, "err": str(e)}
        if t == "fileabort":
            if self._incoming:
                self._incoming.abort()
                self._incoming = None
            return None
        if t == "fileack":          # ack for a file WE are pushing to the phone
            with self._send_cv:
                self._send_acked = max(self._send_acked, int(msg.get("i", -1)) + 1)
                self._send_cv.notify_all()
            return None
        if t == "filedone":         # phone finished receiving our pushed file
            with self._send_cv:
                self._send_done = msg
                self._send_cv.notify_all()
            return None
        return None

    def push_file(self, path, progress=None):
        """Send a local file to this connected phone (GUI -> phone). Runs on a
        worker thread; a small ack window keeps us from outrunning the phone and
        keeps the link's inbound side busy so the heartbeat won't trip."""
        fid = secrets.token_hex(6)
        with self._send_cv:
            self._send_acked = 0
            self._send_stop = False
            self._send_done = None
        try:
            size = os.path.getsize(path)
        except OSError:
            return False
        total = max(1, (size + fx.CHUNK - 1) // fx.CHUNK)
        try:
            for frame in fx.iter_send_frames(path, fid):
                if frame["t"] == "filedat":
                    with self._send_cv:
                        while (frame["i"] - self._send_acked) >= fx.ACK_WINDOW \
                                and not self._send_stop:
                            if not self._send_cv.wait(timeout=20):
                                raise OSError("phone stopped acknowledging")
                        if self._send_stop:
                            return False
                    if progress:
                        try:
                            progress(frame["i"] + 1, total)
                        except Exception:
                            pass
                self.send(frame)
            with self._send_cv:
                if self._send_done is None:
                    self._send_cv.wait(timeout=20)
                done = self._send_done
            return bool(done and done.get("ok"))
        except (OSError, ValueError) as e:
            log(f"    push_file error: {e!r}")
            return False


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    on_event = staticmethod(lambda event, info="": None)

    def register_client(self, h):
        with self.clients_lock:
            if h not in self.clients:
                self.clients.append(h)

    def unregister_client(self, h):
        with self.clients_lock:
            try:
                self.clients.remove(h)
            except ValueError:
                pass

    def latest_client(self):
        """Most recently connected authed phone (for GUI->phone file push)."""
        with self.clients_lock:
            return self.clients[-1] if self.clients else None


def discovery_loop(port, server_name, stop):
    """Answer UDP discovery probes from the app with our server info.
    (Requires a UDP firewall rule; the app also works via manual IP entry.)"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("", port))
    except OSError as e:
        log(f"    (discovery responder off: {e})")
        return
    s.settimeout(1.0)
    reply = json.dumps({"t": "server", "name": server_name, "app": APP,
                        "v": VERSION, "port": port}).encode("utf-8")
    while not stop.is_set():
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break
        if b"discover" in data.lower() and is_lan_ip(addr[0]):
            try:
                s.sendto(reply, addr)
                log(f"    discovery probe from {addr[0]} -> replied")
            except OSError:
                pass
    s.close()


def banner(name, ips, port, pin, require_auth):
    bar = "=" * 56
    log("\n" + bar)
    log(f"  {APP} server  --  '{name}'  is running")
    log(bar)
    log("  In the phone app, connect to one of these addresses:")
    for ip in ips:
        log(f"      {ip} : {port}")
    if ips:
        log(f"\n  Or open in any browser on the same Wi-Fi:  http://{ips[0]}:{port}/")
    if require_auth:
        log(f"\n  PIN:  {pin}      (saved in pin.txt)")
    else:
        log("\n  PIN:  (disabled -- --no-auth)")
    log("\n  Phone must be on the same Wi-Fi.  Ctrl+C to stop.")
    log(bar + "\n")


def build_server(port=DEFAULT_PORT, host="0.0.0.0", pin="", require_auth=True,
                 on_event=None, lan_only=True):
    """Create a configured (not yet running) server. Shared by CLI and GUI."""
    server = Server((host, port), Handler)
    server.require_auth = require_auth
    server.pin = pin
    server.server_name = socket.gethostname()
    server.lan_only = lan_only
    server.web_enabled = True   # browser remote on by default (GUI can toggle)
    server.auth_lock = threading.Lock()
    server.fails = {}   # peer ip -> consecutive bad-PIN count
    server.bans = {}    # peer ip -> unix time the lockout expires
    server.clients = []  # authed Handlers (most recent last) for GUI->phone push
    server.clients_lock = threading.Lock()
    try:
        ips = get_lan_ips()
        server.mac = netinfo.get_primary_mac(ips[0] if ips else None)
    except Exception:
        server.mac = ""
    if on_event is not None:
        server.on_event = on_event
    return server


def start_discovery(port, name):
    """Run the UDP discovery responder in a daemon thread; returns its stop Event."""
    stop = threading.Event()
    threading.Thread(target=discovery_loop, args=(port, name, stop),
                     daemon=True).start()
    return stop


def main():
    ap = argparse.ArgumentParser(description="JawnRemote phone-remote server")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--pin", default=None, help="fixed PIN (else auto/saved)")
    ap.add_argument("--no-auth", action="store_true", help="disable PIN (testing)")
    ap.add_argument("--allow-remote", action="store_true",
                    help="accept non-LAN clients (advanced; default is LAN-only)")
    args = ap.parse_args()

    name = socket.gethostname()
    pin = load_or_create_pin(args.pin)
    ips = get_lan_ips()

    server = build_server(args.port, args.host, pin, not args.no_auth,
                          lan_only=not args.allow_remote)
    stop = start_discovery(args.port, name)

    banner(name, ips, args.port, pin, server.require_auth)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("\nshutting down...")
    finally:
        stop.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
