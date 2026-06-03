"""
Browser remote for JawnRemote -- lets ANY device on the LAN control the PC from
a web browser, no app install. Multiplexed onto the same TCP port (8770) as the
app: server.Handler peeks the first request line and, if it's HTTP, hands the
socket here.

Zero external dependencies -- a tiny stdlib HTTP responder plus a minimal
WebSocket (RFC 6455) implementation. The browser speaks the SAME JSON event
schema as the app, so events route straight through the existing
Handler.do_input(); PIN auth + brute-force lockout are reused verbatim.
"""
import base64
import hashlib
import json
import struct

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# Event types a browser is allowed to send (everything do_input handles except
# nothing dangerous; no file frames over the browser channel in v1).
SAFE_INPUT = {"m", "click", "down", "up", "scroll", "text", "key",
              "power", "launch"}

HTTP_VERBS = (b"GET", b"POST", b"HEAD", b"PUT", b"DELETE", b"OPTIONS")


def looks_like_http(first_line):
    """True if a connection's first line is an HTTP request (vs app JSON)."""
    return first_line.split(b" ", 1)[0] in HTTP_VERBS


# --------------------------------------------------------------------------- #
#  HTTP
# --------------------------------------------------------------------------- #
def serve(handler, first_line, log=print):
    """Handle one HTTP(S-less) connection: serve the page or upgrade to WS."""
    if not getattr(handler.server, "web_enabled", True):
        _http(handler, "403 Forbidden", "text/plain", b"Browser remote is off.")
        return
    try:
        method, target, _ = first_line.decode("latin-1").strip().split(" ", 2)
    except ValueError:
        _http(handler, "400 Bad Request", "text/plain", b"bad request")
        return
    headers = _read_headers(handler.rfile)
    path = target.split("?", 1)[0].split("#", 1)[0]

    if path == "/ws" and "websocket" in headers.get("upgrade", "").lower():
        _websocket(handler, headers, log)
        return
    if method == "GET" and path in ("/", "/index.html"):
        _http(handler, "200 OK", "text/html; charset=utf-8", PAGE.encode("utf-8"))
        return
    _http(handler, "404 Not Found", "text/plain", b"not found")


def _read_headers(rfile):
    headers = {}
    for _ in range(80):  # bounded; defend against a header flood
        line = rfile.readline()
        if not line or line in (b"\r\n", b"\n"):
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().decode("latin-1").lower()] = v.strip().decode("latin-1")
    return headers


def _http(handler, status, ctype, body):
    head = (
        f"HTTP/1.1 {status}\r\n"
        f"Content-Type: {ctype}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n"
    ).encode("latin-1")
    try:
        handler.wfile.write(head + body)
        handler.wfile.flush()
    except OSError:
        pass


# --------------------------------------------------------------------------- #
#  WebSocket (RFC 6455, minimal: small single text frames)
# --------------------------------------------------------------------------- #
def _websocket(handler, headers, log=print):
    key = headers.get("sec-websocket-key")
    if not key:
        _http(handler, "400 Bad Request", "text/plain", b"missing ws key")
        return
    accept = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode("latin-1")).digest()).decode("ascii")
    try:
        handler.wfile.write((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("latin-1"))
        handler.wfile.flush()
    except OSError:
        return
    _ws_loop(handler, log)


def _recv_exact(rfile, n):
    buf = b""
    while len(buf) < n:
        chunk = rfile.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def _ws_recv(rfile):
    """Read one frame -> (opcode, payload) or None on EOF/oversize."""
    head = _recv_exact(rfile, 2)
    if not head:
        return None
    b1, b2 = head[0], head[1]
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    if length == 126:
        ext = _recv_exact(rfile, 2)
        if not ext:
            return None
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = _recv_exact(rfile, 8)
        if not ext:
            return None
        length = struct.unpack("!Q", ext)[0]
    if length > 1_000_000:          # our messages are tiny; refuse anything huge
        return None
    mask = _recv_exact(rfile, 4) if masked else b""
    if masked and mask is None:
        return None
    payload = _recv_exact(rfile, length) if length else b""
    if length and payload is None:
        return None
    if masked and payload:
        payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
    return opcode, payload


def _ws_send_frame(handler, opcode, payload):
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    try:
        handler.wfile.write(head + payload)
        handler.wfile.flush()
    except OSError:
        pass


def _ws_send(handler, obj):
    _ws_send_frame(handler, 0x1, json.dumps(obj).encode("utf-8"))


def _ws_loop(handler, log=print):
    peer = handler.client_address[0]
    srv = handler.server
    authed = not srv.require_auth
    who = None
    log(f"[+] {peer} connected (browser)")
    try:
        while True:
            frame = _ws_recv(handler.rfile)
            if frame is None:
                break
            opcode, payload = frame
            if opcode == 0x8:                       # close
                break
            if opcode == 0x9:                       # ping -> pong
                _ws_send_frame(handler, 0xA, payload)
                continue
            if opcode != 0x1:                       # only text carries JSON
                continue
            try:
                msg = json.loads(payload.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(msg, dict):
                continue
            t = msg.get("t")

            if not authed:
                if t != "hello":
                    continue
                if handler._auth_locked(peer):
                    _ws_send(handler, {"t": "welcome", "ok": False, "err": "locked"})
                    continue
                ok = (not srv.require_auth) or \
                     (str(msg.get("pin", "")) == srv.pin)
                if not ok:
                    handler._record_auth_fail(peer)
                    _ws_send(handler, {"t": "welcome", "ok": False, "err": "bad_pin"})
                    continue
                handler._record_auth_ok(peer)
                authed = True
                who = (str(msg.get("name") or "Browser"))[:40]
                log(f"    browser hello @ {peer}: OK")
                srv.on_event("connected", who)
                _ws_send(handler, {"t": "welcome", "ok": True,
                                   "server": srv.server_name})
                continue

            if t == "ping":
                _ws_send(handler, {"t": "pong"})
            elif t in SAFE_INPUT:
                try:
                    handler.do_input(t, msg)
                except Exception as e:              # never kill the stream
                    log(f"    web input error on {t!r}: {e!r}")
    except (ConnectionError, OSError):
        pass
    finally:
        log(f"[-] {peer} disconnected (browser)")
        if who:
            srv.on_event("disconnected", who)


# --------------------------------------------------------------------------- #
#  The page (self-contained: no external assets)
# --------------------------------------------------------------------------- #
PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="color-scheme" content="dark">
<title>JawnRemote</title>
<style>
  :root{--bg:#0E1116;--card:#161C24;--accent:#4F8CFF;--ink:#fff;--muted:#8A94A6}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);
    font-family:'Segoe UI',system-ui,Arial,sans-serif;overscroll-behavior:none}
  body{display:flex;flex-direction:column;height:100dvh}
  header{display:flex;align-items:center;gap:10px;padding:12px 16px;
    border-bottom:1px solid #ffffff14;font-weight:600}
  #dot{width:10px;height:10px;border-radius:50%;background:#E8A33D}
  #dot.on{background:#3DDC84}
  #pad{flex:1;margin:12px;border-radius:14px;background:var(--card);
    display:flex;align-items:center;justify-content:center;text-align:center;
    color:var(--muted);font-size:14px;touch-action:none;user-select:none;
    -webkit-user-select:none}
  .row{display:flex;gap:10px;padding:0 12px}
  .btn{flex:1;padding:16px;border:none;border-radius:12px;background:var(--card);
    color:var(--ink);font-size:15px;font-weight:600;cursor:pointer;
    touch-action:manipulation}
  .btn:active{background:#1F2733}
  .typerow{display:flex;gap:10px;padding:12px}
  #typer{flex:1;padding:14px;border-radius:12px;border:1px solid #ffffff1f;
    background:var(--card);color:var(--ink);font-size:16px}
  #keys{display:flex;gap:8px;padding:0 12px 12px;flex-wrap:wrap}
  .key{padding:10px 14px;border:none;border-radius:10px;background:var(--card);
    color:var(--ink);font-size:14px;cursor:pointer}
  .key:active{background:#1F2733}
  /* login overlay */
  #login{position:fixed;inset:0;background:var(--bg);display:flex;
    flex-direction:column;align-items:center;justify-content:center;gap:16px;
    padding:24px;z-index:10}
  #login h1{font-size:1.6rem;letter-spacing:.15em;text-transform:uppercase;margin:0}
  #login p{color:var(--muted);margin:0}
  #pin{font-size:24px;letter-spacing:.3em;text-align:center;width:200px;padding:12px;
    border-radius:12px;border:1px solid #ffffff1f;background:var(--card);color:var(--ink)}
  #go{padding:14px 28px;border:none;border-radius:12px;background:var(--accent);
    color:#08101f;font-weight:700;font-size:16px;cursor:pointer}
  #msg{color:#E8A33D;min-height:1.2em}
  .hidden{display:none!important}
</style>
</head>
<body>
  <div id="login">
    <h1>JawnRemote</h1>
    <p>Enter the PIN shown in the PC server window.</p>
    <input id="pin" inputmode="numeric" autocomplete="off" placeholder="PIN">
    <button id="go">Connect</button>
    <div id="msg"></div>
  </div>

  <header><span id="dot"></span><span id="title">Connecting…</span></header>
  <div id="pad">Drag to move &middot; tap to click<br>Two fingers: scroll &middot; two-finger tap: right-click</div>
  <div class="row">
    <button class="btn" id="lclick">Left&nbsp;click</button>
    <button class="btn" id="rclick">Right&nbsp;click</button>
  </div>
  <div class="typerow">
    <input id="typer" placeholder="Tap to type on the PC…" autocomplete="off"
           autocapitalize="off" autocorrect="off" spellcheck="false">
  </div>
  <div id="keys">
    <button class="key" data-k="backspace">⌫</button>
    <button class="key" data-k="enter">⏎</button>
    <button class="key" data-k="tab">Tab</button>
    <button class="key" data-k="escape">Esc</button>
    <button class="key" data-k="up">▲</button>
    <button class="key" data-k="down">▼</button>
    <button class="key" data-k="left">◀</button>
    <button class="key" data-k="right">▶</button>
  </div>

<script>
(function(){
  var MOVE=1.5, SCROLL=3;            // sensitivity
  var ws=null, ready=false, pin="";
  var dot=document.getElementById('dot'), title=document.getElementById('title');
  var login=document.getElementById('login'), msg=document.getElementById('msg');

  function send(o){ if(ws&&ws.readyState===1) ws.send(JSON.stringify(o)); }

  function connect(){
    title.textContent="Connecting…"; dot.classList.remove('on');
    var proto = location.protocol==='https:' ? 'wss://' : 'ws://';
    try { ws = new WebSocket(proto+location.host+'/ws'); }
    catch(e){ retry(); return; }
    ws.onopen=function(){ send({t:'hello',pin:pin,name:'Browser'}); };
    ws.onmessage=function(ev){
      var m; try{ m=JSON.parse(ev.data);}catch(e){return;}
      if(m.t==='welcome'){
        if(m.ok){ ready=true; login.classList.add('hidden');
          dot.classList.add('on'); title.textContent=m.server||'Connected'; }
        else { ready=false; login.classList.remove('hidden');
          msg.textContent = m.err==='locked'
            ? 'Too many tries — wait a minute.' : 'Wrong PIN.'; }
      }
    };
    ws.onclose=function(){ ready=false; dot.classList.remove('on');
      if(!login.classList.contains('hidden')) {} else title.textContent='Reconnecting…';
      retry(); };
    ws.onerror=function(){ try{ws.close();}catch(e){} };
  }
  var retryT=null;
  function retry(){ if(retryT)return; retryT=setTimeout(function(){retryT=null;
    if(pin) connect();},1200); }

  document.getElementById('go').onclick=function(){
    pin=document.getElementById('pin').value.trim(); msg.textContent='';
    if(pin) connect();
  };
  document.getElementById('pin').addEventListener('keydown',function(e){
    if(e.key==='Enter') document.getElementById('go').click(); });

  setInterval(function(){ if(ready) send({t:'ping'}); }, 4000);

  // ---- trackpad ----
  var pad=document.getElementById('pad');
  var pts={}, n=0, last=null, maxN=0, moved=false, startT=0;
  function avgMove(e){
    // average movement of all active pointers since last event
    var p=pts[e.pointerId]; if(!p) return {dx:0,dy:0};
    var dx=e.clientX-p.x, dy=e.clientY-p.y; p.x=e.clientX; p.y=e.clientY;
    return {dx:dx,dy:dy};
  }
  pad.addEventListener('pointerdown',function(e){
    pad.setPointerCapture(e.pointerId);
    pts[e.pointerId]={x:e.clientX,y:e.clientY}; n++;
    if(n===1){ maxN=1; moved=false; startT=Date.now(); } else { maxN=Math.max(maxN,n); }
    e.preventDefault();
  });
  pad.addEventListener('pointermove',function(e){
    if(!pts[e.pointerId]||!ready) { return; }
    var d=avgMove(e);
    if(Math.abs(d.dx)>2||Math.abs(d.dy)>2) moved=true;
    if(n>=2){ if(d.dy) send({t:'scroll',y:Math.round(-d.dy*SCROLL)}); }
    else { if(d.dx||d.dy) send({t:'m',x:Math.round(d.dx*MOVE),y:Math.round(d.dy*MOVE)}); }
    e.preventDefault();
  });
  function up(e){
    if(pts[e.pointerId]){ delete pts[e.pointerId]; n=Math.max(0,n-1); }
    if(n===0){
      var quick=Date.now()-startT<300;
      if(quick&&!moved){
        if(maxN>=2) send({t:'click',b:'right'});
        else if(maxN===1) send({t:'click',b:'left'});
      }
      maxN=0;
    }
    e.preventDefault();
  }
  pad.addEventListener('pointerup',up);
  pad.addEventListener('pointercancel',up);

  // ---- buttons ----
  document.getElementById('lclick').onclick=function(){ send({t:'click',b:'left'}); };
  document.getElementById('rclick').onclick=function(){ send({t:'click',b:'right'}); };

  // ---- typing ----
  var typer=document.getElementById('typer');
  typer.addEventListener('input',function(e){
    if(e.inputType&&e.inputType.indexOf('delete')===0) send({t:'key',k:'backspace'});
    else if(e.data) send({t:'text',s:e.data});
    typer.value='';
  });
  typer.addEventListener('keydown',function(e){
    var map={Enter:'enter',Tab:'tab',Escape:'escape',ArrowUp:'up',ArrowDown:'down',
             ArrowLeft:'left',ArrowRight:'right',Backspace:'backspace'};
    if(map[e.key]){ send({t:'key',k:map[e.key]}); e.preventDefault(); }
  });
  Array.prototype.forEach.call(document.querySelectorAll('#keys .key'),function(b){
    b.addEventListener('click',function(){ send({t:'key',k:b.dataset.k}); typer.focus(); });
  });
})();
</script>
</body>
</html>
"""
