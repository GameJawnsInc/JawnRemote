"""
File transfer for JawnRemote -- stream files between phone and PC over the same
authenticated newline-delimited-JSON TCP connection. Zero external dependencies.

Wire protocol (symmetric -- the same frames flow in either direction; the
"sender" is whoever is pushing the file):

  sender -> receiver:
    {"t":"filebeg","id":..,"name":..,"size":..}
    {"t":"filedat","id":..,"i":<seq>,"b":<base64 of <=CHUNK bytes>}
    {"t":"fileend","id":..,"sha":<hex sha-256 of the whole file>}
    {"t":"fileabort","id":..}
  receiver -> sender:
    {"t":"fileack","id":..,"i":<seq>}   # per chunk: flow control + progress + keep-alive
    {"t":"filedone","id":..,"ok":bool,"path"|"err"}

Received files land in <home>\\Downloads\\JawnRemote\\. The wire "name" is reduced
to a bare, sanitized basename and de-duplicated; nothing from the wire can ever
influence the target directory (path-traversal safe).
"""
import base64
import hashlib
import os
import re

CHUNK = 64 * 1024              # raw bytes per chunk (~88 KB of base64 per line)
MAX_FILE_BYTES = 2 * 1024 ** 3  # 2 GB safety cap on inbound files
ACK_WINDOW = 8                 # max in-flight (unacked) chunks while sending

_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def received_dir():
    """<user home>\\Downloads\\JawnRemote, created if missing."""
    base = os.path.join(os.path.expanduser("~"), "Downloads", "JawnRemote")
    try:
        os.makedirs(base, exist_ok=True)
        return base
    except OSError:
        return os.path.expanduser("~")


def safe_target(name, folder=None):
    """Map an arbitrary wire 'name' to a safe, unique path inside `folder`."""
    folder = folder or received_dir()
    # Basename only -- defeats "../", absolute, and drive-relative paths.
    name = str(name).replace("\\", "/").split("/")[-1]
    name = _BAD.sub("_", name).strip().strip(".")
    name = name[:120] or "file"
    target = os.path.join(folder, name)
    if not os.path.exists(target):
        return target
    stem, ext = os.path.splitext(name)
    i = 1
    while True:
        cand = os.path.join(folder, f"{stem} ({i}){ext}")
        if not os.path.exists(cand):
            return cand
        i += 1


class Incoming:
    """One inbound file, streamed straight to a .part file (never held in RAM)."""

    def __init__(self, msg):
        self.id = msg.get("id")
        self.size = int(msg.get("size", 0) or 0)
        self.final = safe_target(msg.get("name", "file"))
        self.part = self.final + ".part"
        self.next_i = 0
        self.written = 0
        self._h = hashlib.sha256()
        self._f = open(self.part, "wb")

    def write_chunk(self, i, b64):
        if i != self.next_i:
            raise ValueError(f"out-of-order chunk {i} (want {self.next_i})")
        data = base64.b64decode(b64)  # raises binascii.Error (a ValueError) if bad
        self.written += len(data)
        if self.written > MAX_FILE_BYTES:
            raise ValueError("file exceeds size cap")
        self._f.write(data)
        self._h.update(data)
        self.next_i += 1

    def finish(self, sha=None):
        self._f.close()
        if self.size and self.written != self.size:
            self._discard()
            raise ValueError(f"size mismatch ({self.written} != {self.size})")
        sha = (sha or "").lower()
        if sha and self._h.hexdigest() != sha:
            self._discard()
            raise ValueError("checksum mismatch")
        os.replace(self.part, self.final)
        return self.final

    def abort(self):
        try:
            self._f.close()
        except OSError:
            pass
        self._discard()

    def _discard(self):
        try:
            os.remove(self.part)
        except OSError:
            pass


def iter_send_frames(path, fid):
    """Yield the protocol frames to push `path` -- reads the file once, lazily,
    computing the sha-256 on the way (so it rides along in the closing frame)."""
    size = os.path.getsize(path)
    yield {"t": "filebeg", "id": fid, "name": os.path.basename(path), "size": size}
    h = hashlib.sha256()
    i = 0
    with open(path, "rb") as f:
        while True:
            data = f.read(CHUNK)
            if not data:
                break
            h.update(data)
            yield {"t": "filedat", "id": fid, "i": i,
                   "b": base64.b64encode(data).decode("ascii")}
            i += 1
    yield {"t": "fileend", "id": fid, "sha": h.hexdigest()}
