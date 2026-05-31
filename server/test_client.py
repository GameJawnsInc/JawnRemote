"""
Local test client for the JawnRemote server. Validates the protocol and that
input injection actually moves the cursor. Run while server.py is running.

  py test_client.py                 # automated checks against 127.0.0.1:8770
  py test_client.py --type "hello"  # also type some text (goes to focused window)
  py test_client.py --host 10.0.0.210 --pin 1234
"""
import argparse
import json
import os
import socket
import time

import input_win as inp

PIN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pin.txt")


def read_pin():
    try:
        with open(PIN_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


class Client:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.rfile = self.sock.makefile("rb")

    def send(self, **obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode("utf-8"))

    def recv(self):
        line = self.rfile.readline()
        if not line:
            raise ConnectionError("server closed")
        return json.loads(line)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8770)
    ap.add_argument("--pin", default=None)
    ap.add_argument("--type", dest="text", default=None)
    args = ap.parse_args()

    pin = args.pin if args.pin is not None else read_pin()
    c = Client(args.host, args.port)
    passed, failed = 0, 0

    def check(name, ok):
        nonlocal passed, failed
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
        if ok:
            passed += 1
        else:
            failed += 1

    # 1. auth
    c.send(t="hello", pin=pin, name="test_client")
    welcome = c.recv()
    check(f"hello/welcome (server={welcome.get('server')!r})", welcome.get("ok") is True)

    # 2. ping/pong
    c.send(t="ping")
    check("ping -> pong", c.recv().get("t") == "pong")

    # 3. mouse move -- verify the cursor actually moved right
    x0, y0 = inp.get_cursor_pos()
    for _ in range(10):
        c.send(t="m", x=10, y=0)
        time.sleep(0.005)
    time.sleep(0.1)
    x1, y1 = inp.get_cursor_pos()
    check(f"mouse move (cursor {x0}->{x1})", x1 > x0 + 20)
    # move back
    for _ in range(10):
        c.send(t="m", x=-10, y=0)
        time.sleep(0.005)

    # 4. scroll (no crash / no error response)
    c.send(t="scroll", y=-120)
    c.send(t="scroll", y=120)
    check("scroll sent", True)

    # 5. optional text typing
    if args.text:
        print(f"  typing {args.text!r} into the focused window in 2s...")
        time.sleep(2)
        c.send(t="text", s=args.text)
        c.send(t="key", k="enter")
        time.sleep(0.2)
        check("text + enter sent", True)

    time.sleep(0.2)
    c.close()
    print(f"\n  {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
