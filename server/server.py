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
import json
import os
import secrets
import socket
import socketserver
import sys
import threading

import input_win as inp

APP = "JawnRemote"
VERSION = 1
DEFAULT_PORT = 8770
PIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pin.txt")

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

    def send(self, obj):
        try:
            self.wfile.write((json.dumps(obj) + "\n").encode("utf-8"))
            self.wfile.flush()
        except OSError:
            pass

    def handle(self):
        peer = self.client_address[0]
        log(f"[+] {peer} connected")
        try:
            for raw in self.rfile:
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
            log(f"[-] {peer} disconnected")
            if self._who:
                self.server.on_event("disconnected", self._who)

    def dispatch(self, msg):
        t = msg.get("t")
        if t == "hello":
            ok = (not self.server.require_auth) or \
                 (str(msg.get("pin", "")) == self.server.pin)
            self.authed = ok
            who = msg.get("name", "device")
            log(f"    hello from {who!r}: {'OK' if ok else 'BAD PIN'}")
            if not ok:
                return {"t": "welcome", "ok": False, "err": "bad_pin"}
            self._who = who
            self.server.on_event("connected", who)
            return {"t": "welcome", "ok": True, "server": self.server.server_name,
                    "app": APP, "v": VERSION}
        if t == "ping":
            return {"t": "pong"}
        if not self.authed:
            return {"t": "error", "err": "unauthorized"}
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


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    on_event = staticmethod(lambda event, info="": None)


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
        if b"discover" in data.lower():
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
    if require_auth:
        log(f"\n  PIN:  {pin}      (saved in pin.txt)")
    else:
        log("\n  PIN:  (disabled -- --no-auth)")
    log("\n  Phone must be on the same Wi-Fi.  Ctrl+C to stop.")
    log(bar + "\n")


def build_server(port=DEFAULT_PORT, host="0.0.0.0", pin="", require_auth=True,
                 on_event=None):
    """Create a configured (not yet running) server. Shared by CLI and GUI."""
    server = Server((host, port), Handler)
    server.require_auth = require_auth
    server.pin = pin
    server.server_name = socket.gethostname()
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
    args = ap.parse_args()

    name = socket.gethostname()
    pin = load_or_create_pin(args.pin)
    ips = get_lan_ips()

    server = build_server(args.port, args.host, pin, not args.no_auth)
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
