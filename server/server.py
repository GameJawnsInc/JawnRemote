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
import errno
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
import gamepad_win as pad

APP = "JawnRemote"
VERSION = 1
DEFAULT_PORT = 8770
PIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pin.txt")

# Brute-force protection: temporarily refuse an IP after too many bad PINs.
MAX_PIN_FAILS = 5
LOCKOUT_SECONDS = 60

# Seconds a freshly-accepted socket has to send its first line before we reap it.
# Stops idle browser preconnects / half-open sockets from pinning a handler
# thread forever (cleared once an app connection is established).
HANDSHAKE_TIMEOUT = 20

# Idle read timeout for an established app connection. The app pings every ~4s,
# so a live client never trips it; a half-open/abandoned one (phone slept, Wi-Fi
# roamed, force-quit without a FIN) is reaped instead of lingering as a zombie
# the GUI's "Send file" could target.
APP_IDLE_TIMEOUT = 20

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


def _xfer_err(e):
    """User-facing text for a failed inbound file (sent back to the phone)."""
    if getattr(e, "errno", None) == errno.ENOSPC:
        return "The PC's disk is full"
    return str(e)


class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        super().setup()
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        self.authed = not self.server.require_auth
        self._who = None
        self._pad_active = False        # this connection has plugged a virtual pad
        self._incoming = None           # in-progress inbound file (phone -> PC)
        self._wlock = threading.Lock()  # serialize writes (read-loop vs GUI push)
        self._send_cv = threading.Condition()  # outbound push ack signaling
        self._push_lock = threading.Lock()     # one GUI -> phone push at a time
        self._send_id = None            # id of the push acks/filedone must match
        self._send_acked = 0
        self._send_stop = False
        self._send_done = None
        self._closed = False            # socket gone: wakes a push to fail fast

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
        # Reap a socket that connects but never sends a first line (idle browser
        # preconnects, half-open WebSockets). Without a timeout the handler
        # thread blocks here forever; under the browser's reconnect loop these
        # pile up and starve the web side while the app's one persistent
        # connection sails on -- the "web spins until I restart" symptom.
        try:
            self.connection.settimeout(HANDSHAKE_TIMEOUT)
        except OSError:
            pass
        try:
            first = self.rfile.readline()
        except OSError:                  # timeout or reset before any data
            return
        if not first:
            return
        if web_remote.looks_like_http(first):
            # A browser hit the same port -> serve the no-install web remote.
            try:
                web_remote.serve(self, first, log=log)
            except (ConnectionError, OSError):
                pass
            finally:
                self._release_held()     # the page's input runs on this Handler
            return
        # App path: long-lived. The app pings every ~4s, so a generous idle
        # timeout reaps a dead/abandoned connection (zombie) without ever
        # tripping a healthy one -- the steady inbound ping traffic keeps it
        # alive, and active transfers keep data flowing too.
        try:
            self.connection.settimeout(APP_IDLE_TIMEOUT)
        except OSError:
            pass
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
            self._release_held()
            # An upload cut off by the drop would otherwise leave a .part file
            # behind (the app never resumes; it retries from scratch).
            inc, self._incoming = self._incoming, None
            if inc:
                try:
                    inc.abort()
                except Exception:
                    pass
                log("    incomplete upload discarded")
            # Wake a GUI push waiting on this connection so it fails now
            # instead of sitting out its ack timeout.
            with self._send_cv:
                self._closed = True
                self._send_cv.notify_all()
            # Failsafe: if this connection drove a virtual gamepad, release all
            # inputs the moment the socket drops or is reaped -- otherwise a
            # held stick/button stays held (character runs forever). The pad
            # unplugs after a short grace unless a reconnect picks it back up,
            # and is left alone if a newer connection drives it by now.
            if self._pad_active:
                pad.release(self)
                self._pad_active = False
            self.server.unregister_client(self)
            log(f"[-] {peer} disconnected")
            if self._who is not None:
                self.server.on_event("disconnected", self._who)

    def _release_held(self):
        """Failsafe: let go of any mouse button this connection pressed and
        never released (the link dropped mid-drag). A button another
        connection has pressed since is left alone, so its drag isn't cut."""
        with self.server.btn_lock:
            for b, h in list(self.server.btn_holder.items()):
                if h is self:
                    del self.server.btn_holder[b]
                    try:
                        inp.mouse_up(b)
                    except Exception:
                        pass

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
            who = str(msg.get("name") or "device")
            if not ok:
                self._record_auth_fail(peer)
                log(f"    hello from {who!r} @ {peer}: BAD PIN")
                return {"t": "welcome", "ok": False, "err": "bad_pin"}
            self._record_auth_ok(peer)
            self.authed = True
            self.server.register_client(self)
            log(f"    hello from {who!r} @ {peer}: OK")
            # One "connected" per connection, paired with the "disconnected"
            # in handle()'s finally -- a repeated hello must not add another.
            if self._who is None:
                self._who = who
                self.server.on_event("connected", who)
            # The MAC of the adapter the phone actually reached us on (right
            # for Wake-on-LAN even with a VPN / virtual adapter present).
            try:
                mac = netinfo.mac_for_ip(self.connection.getsockname()[0])
            except Exception:
                mac = ""
            return {"t": "welcome", "ok": True, "server": self.server.server_name,
                    "app": APP, "v": VERSION,
                    "mac": mac or getattr(self.server, "mac", "")}
        if t == "ping":
            return {"t": "pong"}
        if not self.authed:
            return {"t": "error", "err": "unauthorized"}
        if t == "getapps":
            return {"t": "apps", "apps": appstore.load_apps()}
        if t == "clipget":
            return {"t": "clip", "s": clip.get_text()}
        if t == "displays":
            try:
                return {"t": "displays", "list": screen_win.list_displays()}
            except Exception as e:
                log(f"    displays error: {e!r}")
                return {"t": "displays", "list": []}
        if t == "shot":
            try:
                png, w, h = screen_win.capture_png(display=msg.get("display"))
                return {"t": "shot", "w": w, "h": h,
                        "img": base64.b64encode(png).decode("ascii")}
            except Exception as e:
                log(f"    shot error: {e!r}")
                return {"t": "shot", "err": True}
        if t == "padconnect":
            ok = pad.plug(owner=self)
            if ok:
                self._pad_active = True
                log("    gamepad: virtual pad plugged in")
            else:
                log(f"    gamepad unavailable: {pad.last_error()}")
            return {"t": "padstatus", "ok": ok,
                    "err": None if ok else pad.last_error()}
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
        elif t in ("click", "down", "up"):
            b = msg.get("b", "left")
            b = b if b in ("left", "right", "middle") else "left"
            # Remember who holds a pressed button so a connection that drops
            # mid-drag can release it (see _release_held).
            with self.server.btn_lock:
                if t == "down":
                    inp.mouse_down(b)
                    self.server.btn_holder[b] = self
                elif t == "up":
                    inp.mouse_up(b)
                    self.server.btn_holder.pop(b, None)
                else:                   # a click leaves the button up too
                    inp.click(b)
                    self.server.btn_holder.pop(b, None)
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
            else:
                log(f"    launch failed (not found?): {target}")
        elif t == "clipset":
            s = msg.get("s", "")
            if isinstance(s, str) and clip.set_text(s):
                log("    clipboard set from phone")
        elif t == "pad":
            # Stateful: holds until the next state. apply_msg auto-plugs if a
            # padconnect was missed, so mark the connection for failsafe cleanup.
            if pad.apply_msg(msg, owner=self):
                self._pad_active = True
        elif t == "paddisconnect":
            pad.unplug()
            self._pad_active = False

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
                return {"t": "filedone", "id": fid, "ok": False, "err": _xfer_err(e)}
            return {"t": "fileack", "id": fid, "i": -1}
        if t == "filedat":
            inc = self._incoming
            if not inc or inc.id != fid:
                return {"t": "filedone", "id": fid, "ok": False,
                        "err": "Transfer interrupted — try again"}
            try:
                i = int(msg.get("i", -1))
                inc.write_chunk(i, msg.get("b", ""))
                return {"t": "fileack", "id": fid, "i": i}
            except (OSError, ValueError) as e:
                inc.abort()
                self._incoming = None
                return {"t": "filedone", "id": fid, "ok": False, "err": _xfer_err(e)}
        if t == "fileend":
            inc = self._incoming
            if not inc or inc.id != fid:
                return {"t": "filedone", "id": fid, "ok": False,
                        "err": "Transfer interrupted — try again"}
            try:
                path = inc.finish(msg.get("sha"))
                self._incoming = None
                log(f"    received file -> {path}")
                self.server.on_event("file_in", os.path.basename(path))
                return {"t": "filedone", "id": fid, "ok": True, "path": path}
            except (OSError, ValueError) as e:
                inc.abort()
                self._incoming = None
                return {"t": "filedone", "id": fid, "ok": False, "err": _xfer_err(e)}
        if t == "fileabort":
            if self._incoming:
                self._incoming.abort()
                self._incoming = None
            return None
        if t == "fileack":          # ack for a file WE are pushing to the phone
            with self._send_cv:
                if fid != self._send_id:    # a stale/other transfer's ack
                    return None
                self._send_acked = max(self._send_acked, int(msg.get("i", -1)) + 1)
                self._send_cv.notify_all()
            return None
        if t == "filedone":         # phone finished receiving our pushed file
            with self._send_cv:
                if fid != self._send_id:
                    return None
                self._send_done = msg
                self._send_cv.notify_all()
            return None
        return None

    def push_file(self, path, progress=None):
        """Send a local file to this connected phone (GUI -> phone). Runs on a
        worker thread; a small ack window keeps us from outrunning the phone and
        keeps the link's inbound side busy so the heartbeat won't trip.
        Returns (ok, err): err is a short reason for the GUI, or None if the
        push was stopped. One push at a time per connection."""
        if not self._push_lock.acquire(blocking=False):
            return False, "already sending a file"
        try:
            return self._push_file(path, progress)
        finally:
            self._push_lock.release()

    def _push_file(self, path, progress):
        fid = secrets.token_hex(6)
        with self._send_cv:
            if self._closed:
                return False, "phone disconnected"
            self._send_id = fid
            self._send_acked = 0
            self._send_stop = False
            self._send_done = None
        try:
            size = os.path.getsize(path)
        except OSError:
            return False, "couldn't read the file"
        total = max(1, (size + fx.CHUNK - 1) // fx.CHUNK)
        try:
            for frame in fx.iter_send_frames(path, fid):
                if frame["t"] == "filedat":
                    with self._send_cv:
                        # Also stop waiting the moment the phone drops or gives
                        # up (an early filedone ok:false) -- no 20 s hang.
                        while (frame["i"] - self._send_acked) >= fx.ACK_WINDOW \
                                and not self._send_stop and not self._closed \
                                and self._send_done is None:
                            if not self._send_cv.wait(timeout=20):
                                raise TimeoutError("phone stopped acknowledging")
                        closed = self._closed
                        failed = self._send_done is not None
                        stopped = self._send_stop
                    if closed:
                        return False, "phone disconnected"
                    if failed or stopped:
                        self.send({"t": "fileabort", "id": fid})
                        return False, "the phone couldn't save it" if failed else None
                    if progress:
                        try:
                            progress(frame["i"] + 1, total)
                        except Exception:
                            pass
                self.send(frame)
            # Wait for the phone's final `filedone`. fileacks for the last
            # chunks share this condition variable (both notify_all), so a
            # single `if ... wait` gets woken early by a trailing ack with
            # _send_done still None -> spurious False. That surfaced as
            # "Couldn't send (is the app open?)" even though the file arrived.
            # Loop on the real condition until filedone, a drop or a true timeout.
            deadline = time.monotonic() + 20
            with self._send_cv:
                while self._send_done is None and not self._closed:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    self._send_cv.wait(timeout=remaining)
                done = self._send_done
                closed = self._closed
            if done is not None:
                if done.get("ok"):
                    return True, None
                return False, "the phone couldn't save it"
            if closed:
                return False, "phone disconnected"
            return False, "no reply from the phone"
        except (OSError, ValueError) as e:
            log(f"    push_file error: {e!r}")
            if self._closed:
                return False, "phone disconnected"
            self.send({"t": "fileabort", "id": fid})
            if isinstance(e, TimeoutError):
                return False, "phone stopped responding"
            return False, "couldn't read the file"


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128   # absorb bursts (a browser opens several at once)
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
    errors = 0
    while not stop.is_set():
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            continue
        except ConnectionResetError:
            # Windows (WSAECONNRESET): an earlier reply hit a phone socket that
            # had already closed. Only that ICMP echo -- the socket is fine.
            continue
        except OSError as e:
            if stop.is_set():
                break
            errors += 1
            if errors >= 30:            # truly dead socket: don't spin forever
                log(f"    (discovery responder stopped: {e})")
                break
            if errors == 1:
                log(f"    (discovery recv error: {e})")
            time.sleep(1.0)
            continue
        errors = 0
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
    server.btn_holder = {}  # mouse button -> Handler that pressed it (not yet up)
    server.btn_lock = threading.Lock()
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
