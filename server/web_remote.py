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

import apps_store
import clipboard_win as clip
import screen_win

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# A live page pings every few seconds, so a WebSocket idle longer than this is
# gone (phone asleep, Wi-Fi roamed, tab closed without a close frame). Let the
# read time out and free the handler thread instead of blocking on it forever.
WS_IDLE_TIMEOUT = 30

# Event types a browser is allowed to send (everything do_input handles except
# nothing dangerous; no file frames over the browser channel in v1).
SAFE_INPUT = {"m", "click", "down", "up", "scroll", "text", "key",
              "power", "launch", "clipset"}

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
    try:
        handler.connection.settimeout(WS_IDLE_TIMEOUT)
    except OSError:
        pass
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
            elif t == "clipget":
                try:
                    _ws_send(handler, {"t": "clip", "s": clip.get_text()})
                except Exception as e:
                    log(f"    web clipget error: {e!r}")
            elif t == "getapps":
                try:
                    _ws_send(handler, {"t": "apps", "apps": apps_store.load_apps()})
                except Exception as e:
                    log(f"    web getapps error: {e!r}")
            elif t == "displays":
                try:
                    _ws_send(handler, {"t": "displays",
                                       "list": screen_win.list_displays()})
                except Exception as e:
                    log(f"    web displays error: {e!r}")
                    _ws_send(handler, {"t": "displays", "list": []})
            elif t == "shot":
                try:
                    png, w, h = screen_win.capture_png(display=msg.get("display"))
                    _ws_send(handler, {"t": "shot", "w": w, "h": h,
                                       "img": base64.b64encode(png).decode("ascii")})
                except Exception as e:
                    log(f"    web shot error: {e!r}")
                    _ws_send(handler, {"t": "shot", "err": True})
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
  :root{--bg:#0E1116;--card:#161C24;--accent:#4F8CFF;--ink:#fff;--muted:#8A94A6;--amber:#E8A33D;--green:#3DDC84;--red:#FF6B6B}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);
    font-family:'Segoe UI',system-ui,Arial,sans-serif;overscroll-behavior:none}
  body{display:flex;flex-direction:column;height:100dvh}
  header{display:flex;align-items:center;gap:10px;padding:12px 16px;flex:none;
    border-bottom:1px solid #ffffff14;font-weight:600}
  #dot{width:10px;height:10px;border-radius:50%;background:var(--amber);flex:none}
  #dot.on{background:var(--green)}
  #title{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  main{flex:1;min-height:0;display:flex;flex-direction:column}
  .panel{flex:1;min-height:0;display:none;flex-direction:column;gap:12px;padding:12px;
    overflow-y:auto;-webkit-overflow-scrolling:touch}
  .panel.on{display:flex}
  #pad{flex:1;min-height:200px;border-radius:14px;background:var(--card);
    display:flex;align-items:center;justify-content:center;text-align:center;
    color:var(--muted);font-size:14px;line-height:1.6;padding:16px;
    touch-action:none;user-select:none;-webkit-user-select:none}
  .row{display:flex;gap:10px}
  .btn{padding:16px;border:none;border-radius:12px;background:var(--card);
    color:var(--ink);font-size:15px;font-weight:600;cursor:pointer;
    touch-action:manipulation}
  .row .btn{flex:1}
  .btn:active{background:#1F2733}
  .btn.danger{color:var(--red)}
  #typer{width:100%;padding:14px;border-radius:12px;border:1px solid #ffffff1f;
    background:var(--card);color:var(--ink);font-size:16px}
  .keys{display:flex;gap:8px;flex-wrap:wrap}
  .key{padding:11px 15px;border:none;border-radius:10px;background:var(--card);
    color:var(--ink);font-size:14px;cursor:pointer;touch-action:manipulation}
  .key:active{background:#1F2733}
  .key.mod.on{background:var(--accent);color:#08101f}
  .label{color:var(--muted);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
  details summary{color:var(--muted);font-size:13px;cursor:pointer;padding:4px 0}
  #clipbox{width:100%;height:88px;padding:12px;border-radius:12px;resize:none;
    border:1px solid #ffffff1f;background:var(--card);color:var(--ink);
    font-size:15px;font-family:inherit}
  .grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
  .bigbtn{padding:20px 4px;border:none;border-radius:14px;background:var(--card);
    color:var(--ink);font-size:15px;font-weight:600;cursor:pointer;
    touch-action:manipulation}
  .bigbtn:active{background:#1F2733}
  #appgrid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}
  .app{padding:18px 12px;border:none;border-left:4px solid var(--accent);
    border-radius:12px;background:var(--card);color:var(--ink);font-size:15px;
    font-weight:600;text-align:left;cursor:pointer;touch-action:manipulation;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .app:active{background:#1F2733}
  .hint{color:var(--muted);font-size:13px;text-align:center;padding:16px}
  nav#tabs{display:flex;flex:none;border-top:1px solid #ffffff14}
  .tab{flex:1;padding:13px 2px;background:none;border:none;color:var(--muted);
    font-size:13px;font-weight:600;letter-spacing:.03em;cursor:pointer}
  .tab.on{color:var(--accent);box-shadow:inset 0 2px 0 var(--accent)}
  #login{position:fixed;inset:0;background:var(--bg);display:flex;
    flex-direction:column;align-items:center;justify-content:center;gap:16px;
    padding:24px;z-index:10}
  #login h1{font-size:1.6rem;letter-spacing:.15em;text-transform:uppercase;margin:0}
  #login p{color:var(--muted);margin:0;text-align:center}
  #pin{font-size:24px;letter-spacing:.3em;text-align:center;width:200px;padding:12px;
    border-radius:12px;border:1px solid #ffffff1f;background:var(--card);color:var(--ink)}
  #go{padding:14px 28px;border:none;border-radius:12px;background:var(--accent);
    color:#08101f;font-weight:700;font-size:16px;cursor:pointer}
  #msg{color:var(--amber);min-height:1.2em}
  #shot{position:fixed;inset:0;z-index:20;background:#000;display:flex;flex-direction:column}
  #shotstage{flex:1;min-height:0;position:relative;overflow:hidden;touch-action:none}
  #shotimg{position:absolute;left:0;top:0;transform-origin:0 0;
    will-change:transform;user-select:none;-webkit-user-select:none;-webkit-user-drag:none}
  #shotmsg{position:absolute;top:50%;left:0;right:0;transform:translateY(-50%);
    text-align:center;color:var(--muted)}
  #shotbar{flex:none;display:flex;gap:8px;padding:10px;background:var(--bg);
    border-top:1px solid #ffffff14}
  #shotbar .btn{flex:1;padding:13px}
  #shotbar .btn.wide{flex:2}
  #shotdisp{flex:none;display:flex;gap:6px;padding:8px;background:var(--bg);
    overflow-x:auto;border-bottom:1px solid #ffffff14}
  #shotdisp:empty{display:none}
  #shotdisp .chip{flex:none;padding:8px 14px;border:none;border-radius:8px;
    background:var(--card);color:var(--ink);font-size:13px;white-space:nowrap;
    cursor:pointer}
  #shotdisp .chip.on{background:var(--accent);color:#08101f;font-weight:600}
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

  <main>
    <section class="panel on" data-panel="touch">
      <div id="pad">Drag to move &middot; tap to click<br>Two fingers: scroll &middot; two-finger tap: right-click<br>Double-tap &amp; hold to drag</div>
      <div class="row">
        <button class="btn" id="lclick">Left&nbsp;click</button>
        <button class="btn" id="rclick">Right&nbsp;click</button>
      </div>
    </section>

    <section class="panel" data-panel="keys">
      <input id="typer" placeholder="Tap to type on the PC…" autocomplete="off"
             autocapitalize="off" autocorrect="off" spellcheck="false">
      <div class="keys">
        <button class="key" data-k="backspace">⌫</button>
        <button class="key" data-k="enter">⏎</button>
        <button class="key" data-k="tab">Tab</button>
        <button class="key" data-k="escape">Esc</button>
        <button class="key" data-k="delete">Del</button>
        <button class="key" data-k="up">▲</button>
        <button class="key" data-k="down">▼</button>
        <button class="key" data-k="left">◀</button>
        <button class="key" data-k="right">▶</button>
      </div>
      <div class="label">Modifiers — tap, then a key or letter</div>
      <div class="keys">
        <button class="key mod" data-mod="ctrl">Ctrl</button>
        <button class="key mod" data-mod="alt">Alt</button>
        <button class="key mod" data-mod="shift">Shift</button>
        <button class="key mod" data-mod="win">Win</button>
      </div>
      <div class="label">Shortcuts</div>
      <div class="keys">
        <button class="key" data-k="c" data-m="ctrl">Copy</button>
        <button class="key" data-k="v" data-m="ctrl">Paste</button>
        <button class="key" data-k="x" data-m="ctrl">Cut</button>
        <button class="key" data-k="z" data-m="ctrl">Undo</button>
        <button class="key" data-k="a" data-m="ctrl">All</button>
        <button class="key" data-k="s" data-m="ctrl">Save</button>
        <button class="key" data-k="tab" data-m="alt">Alt+Tab</button>
        <button class="key" data-k="f4" data-m="alt">Alt+F4</button>
        <button class="key" data-k="d" data-m="win">Win+D</button>
        <button class="key" data-k="e" data-m="win">Win+E</button>
        <button class="key" data-k="printscreen">PrtSc</button>
      </div>
      <details>
        <summary>Function keys</summary>
        <div class="keys" id="fkeys"></div>
      </details>
      <div class="label">Clipboard</div>
      <textarea id="clipbox" placeholder="Type or paste here, then Send to PC. Get from PC fills this box."></textarea>
      <div class="row">
        <button class="btn" id="clipsend">Send to PC</button>
        <button class="btn" id="clipgetb">Get from PC</button>
      </div>
      <div class="label">Screen</div>
      <button class="btn" id="shotbtn">Quick View</button>
    </section>

    <section class="panel" data-panel="media">
      <div class="label">Media</div>
      <div class="grid3">
        <button class="bigbtn" data-k="mediaprev">Prev</button>
        <button class="bigbtn" data-k="mediaplaypause">Play / Pause</button>
        <button class="bigbtn" data-k="medianext">Next</button>
      </div>
      <div class="label">Volume</div>
      <div class="grid3">
        <button class="bigbtn" data-rk="volumedown">Vol &minus;</button>
        <button class="bigbtn" data-k="volumemute">Mute</button>
        <button class="bigbtn" data-rk="volumeup">Vol +</button>
      </div>
      <div class="label">Presentation</div>
      <div class="grid3">
        <button class="bigbtn" data-k="f5">Start</button>
        <button class="bigbtn" data-k="pageup">Prev</button>
        <button class="bigbtn" data-k="pagedown">Next</button>
        <button class="bigbtn" data-k="b">Black</button>
        <button class="bigbtn" data-k="escape">End</button>
      </div>
    </section>

    <section class="panel" data-panel="power">
      <div class="label">Power</div>
      <button class="btn" data-power="lock">Lock</button>
      <button class="btn" data-power="sleep">Sleep</button>
      <button class="btn danger" data-power="restart" data-confirm="Restart the PC?">Restart</button>
      <button class="btn danger" data-power="shutdown" data-confirm="Shut down the PC?">Shut down</button>
      <button class="btn danger" data-power="logoff" data-confirm="Log off the PC?">Log off</button>
    </section>

    <section class="panel" data-panel="apps">
      <div id="appgrid"></div>
      <div class="hint" id="appshint">Loading your apps…</div>
    </section>
  </main>

  <nav id="tabs">
    <button class="tab on" data-tab="touch">Touch</button>
    <button class="tab" data-tab="keys">Keys</button>
    <button class="tab" data-tab="media">Media</button>
    <button class="tab" data-tab="power">Power</button>
    <button class="tab" data-tab="apps">Apps</button>
  </nav>

  <div id="shot" class="hidden">
    <div id="shotdisp"></div>
    <div id="shotstage">
      <img id="shotimg" alt="">
      <div id="shotmsg">Capturing…</div>
    </div>
    <div id="shotbar">
      <button class="btn" id="shotout">&minus;</button>
      <button class="btn" id="shotin">+</button>
      <button class="btn" id="shotref">Refresh</button>
      <button class="btn wide" id="shotclose">Close</button>
    </div>
  </div>

<script>
(function(){
  var MOVE=1.5, SCROLL=3;            // sensitivity
  var ws=null, ready=false, pin="", appsLoaded=false;
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
        if(m.ok){ ready=true; retryMs=800; login.classList.add('hidden');
          dot.classList.add('on'); title.textContent=m.server||'Connected';
          try{ localStorage.setItem('jr_pin', pin); }catch(e){}   // remember for reconnect
          send({t:'displays'}); }
        else { ready=false; login.classList.remove('hidden');
          if(m.err!=='locked'){ try{ localStorage.removeItem('jr_pin'); }catch(e){} }
          msg.textContent = m.err==='locked'
            ? 'Too many tries — wait a minute.' : 'Wrong PIN.'; }
      } else if(m.t==='clip'){
        document.getElementById('clipbox').value = m.s||'';
      } else if(m.t==='apps'){
        renderApps(m.apps||[]);
      } else if(m.t==='displays'){
        onDisplays(m.list||[]);
      } else if(m.t==='shot'){
        onShot(m);
      }
    };
    ws.onclose=function(){ ready=false; dot.classList.remove('on');
      if(login.classList.contains('hidden')) title.textContent='Reconnecting…';
      retry(); };
    ws.onerror=function(){ try{ws.close();}catch(e){} };
  }
  var retryT=null, retryMs=800;
  function retry(){ if(retryT)return; retryT=setTimeout(function(){retryT=null;
    if(pin) connect();}, retryMs);
    retryMs=Math.min(Math.round(retryMs*1.6), 8000); }   // back off, don't hammer

  document.getElementById('go').onclick=function(){
    pin=document.getElementById('pin').value.trim(); msg.textContent='';
    if(pin) connect();
  };
  document.getElementById('pin').addEventListener('keydown',function(e){
    if(e.key==='Enter') document.getElementById('go').click(); });

  setInterval(function(){ if(ready) send({t:'ping'}); }, 4000);

  // ---- tabs ----
  function showTab(name){
    Array.prototype.forEach.call(document.querySelectorAll('.tab'),function(b){
      b.classList.toggle('on', b.dataset.tab===name); });
    Array.prototype.forEach.call(document.querySelectorAll('.panel'),function(p){
      p.classList.toggle('on', p.dataset.panel===name); });
    if(name!=='keys'){ var a=document.activeElement; if(a&&a.blur) a.blur(); }
    if(name==='apps' && !appsLoaded) send({t:'getapps'});
  }
  Array.prototype.forEach.call(document.querySelectorAll('.tab'),function(b){
    b.addEventListener('click',function(){ showTab(b.dataset.tab); });
  });

  // ---- modifiers (one-shot, applied to the next key/letter) ----
  var armed=[];
  function clearMods(){ armed=[];
    Array.prototype.forEach.call(document.querySelectorAll('.mod'),function(b){
      b.classList.remove('on'); }); }
  Array.prototype.forEach.call(document.querySelectorAll('.mod'),function(b){
    b.addEventListener('click',function(){
      var m=b.dataset.mod, i=armed.indexOf(m);
      if(i>=0){ armed.splice(i,1); b.classList.remove('on'); }
      else { armed.push(m); b.classList.add('on'); }
    });
  });
  function sendKey(k){ send({t:'key',k:k,m:armed.slice()}); if(armed.length) clearMods(); }

  // ---- trackpad ----
  var pad=document.getElementById('pad');
  var pts={}, n=0, maxN=0, moved=false, startT=0, sx=0, sy=0;
  var lastUp=0, lux=0, luy=0, holding=false;
  function avgMove(e){
    var p=pts[e.pointerId]; if(!p) return {dx:0,dy:0};
    var dx=e.clientX-p.x, dy=e.clientY-p.y; p.x=e.clientX; p.y=e.clientY;
    return {dx:dx,dy:dy};
  }
  pad.addEventListener('pointerdown',function(e){
    pad.setPointerCapture(e.pointerId);
    pts[e.pointerId]={x:e.clientX,y:e.clientY}; n++;
    if(n===1){
      maxN=1; moved=false; startT=Date.now(); sx=e.clientX; sy=e.clientY;
      // double-tap-and-hold: a quick 2nd tap near the 1st holds the left button
      // (the OS reads it as double-click-drag -> select text / move windows)
      if(Date.now()-lastUp<300 && Math.hypot(e.clientX-lux,e.clientY-luy)<30){
        holding=true; send({t:'down',b:'left'});
      }
    } else { maxN=Math.max(maxN,n); }
    // touching the pad leaves the type field so the on-screen keyboard hides
    if(document.activeElement&&document.activeElement.blur) document.activeElement.blur();
    e.preventDefault();
  });
  pad.addEventListener('pointermove',function(e){
    if(!pts[e.pointerId]||!ready) return;
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
      if(holding){ send({t:'up',b:'left'}); holding=false; }
      else if(quick&&!moved){
        if(maxN>=2) send({t:'click',b:'right'});
        else { send({t:'click',b:'left'}); lastUp=Date.now(); lux=sx; luy=sy; }
      }
      maxN=0;
    }
    e.preventDefault();
  }
  pad.addEventListener('pointerup',up);
  pad.addEventListener('pointercancel',up);

  document.getElementById('lclick').onclick=function(){ send({t:'click',b:'left'}); };
  document.getElementById('rclick').onclick=function(){ send({t:'click',b:'right'}); };

  // ---- typing ----
  var typer=document.getElementById('typer');
  typer.addEventListener('input',function(e){
    if(e.inputType&&e.inputType.indexOf('delete')===0){ send({t:'key',k:'backspace'}); }
    else if(e.data){
      if(armed.length && e.data.length===1) sendKey(e.data);
      else send({t:'text',s:e.data});
    }
    typer.value='';
  });
  typer.addEventListener('keydown',function(e){
    var map={Enter:'enter',Tab:'tab',Escape:'escape',ArrowUp:'up',ArrowDown:'down',
             ArrowLeft:'left',ArrowRight:'right',Backspace:'backspace'};
    if(map[e.key]){ sendKey(map[e.key]); e.preventDefault(); }
  });

  // ---- key buttons: nav + shortcuts + F-keys ----
  var fk=document.getElementById('fkeys');
  for(var i=1;i<=12;i++){ var fb=document.createElement('button');
    fb.className='key'; fb.setAttribute('data-k','f'+i); fb.textContent='F'+i;
    fk.appendChild(fb); }
  Array.prototype.forEach.call(document.querySelectorAll('.keys .key'),function(b){
    if(b.classList.contains('mod')) return;
    b.addEventListener('click',function(){
      if(b.dataset.m) send({t:'key',k:b.dataset.k,m:b.dataset.m.split('+')});
      else { sendKey(b.dataset.k); typer.focus(); }
    });
  });

  // ---- media / presentation (single) + volume (repeat-on-hold) ----
  Array.prototype.forEach.call(document.querySelectorAll('[data-k]'),function(b){
    if(b.closest('.keys')) return;            // nav/shortcut/F-keys wired above
    b.addEventListener('click',function(){ send({t:'key',k:b.dataset.k}); });
  });
  Array.prototype.forEach.call(document.querySelectorAll('[data-rk]'),function(b){
    var timer=null, k=b.dataset.rk;
    function fire(){ send({t:'key',k:k}); }
    function stop(){ if(timer){ clearInterval(timer); timer=null; } }
    b.addEventListener('pointerdown',function(e){ fire(); timer=setInterval(fire,180); e.preventDefault(); });
    b.addEventListener('pointerup',stop);
    b.addEventListener('pointerleave',stop);
    b.addEventListener('pointercancel',stop);
  });

  // ---- power ----
  Array.prototype.forEach.call(document.querySelectorAll('[data-power]'),function(b){
    b.addEventListener('click',function(){
      var c=b.dataset.confirm;
      if(c && !window.confirm(c)) return;
      send({t:'power',action:b.dataset.power});
    });
  });

  // ---- clipboard ----
  document.getElementById('clipsend').onclick=function(){
    send({t:'clipset',s:document.getElementById('clipbox').value}); };
  document.getElementById('clipgetb').onclick=function(){ send({t:'clipget'}); };

  // ---- apps ----
  function renderApps(apps){
    appsLoaded=true;
    var g=document.getElementById('appgrid'); g.innerHTML='';
    var hint=document.getElementById('appshint');
    if(!apps.length){ hint.style.display=''; hint.textContent='No apps configured yet — add them in the PC app list.'; return; }
    hint.style.display='none';
    apps.forEach(function(a){
      var b=document.createElement('button'); b.className='app'; b.textContent=a.name;
      if(a.color) b.style.borderLeftColor='#'+a.color;
      b.addEventListener('click',function(){ send({t:'launch',target:a.target}); });
      g.appendChild(b);
    });
  }

  // ---- quick view: a one-off screenshot you can pinch/drag to zoom ----
  // Nothing is saved anywhere -- the PNG arrives over the socket, lives in an
  // <img>, and is dropped the moment you close the viewer.
  var shotEl=document.getElementById('shot'),
      simg=document.getElementById('shotimg'),
      shotmsg=document.getElementById('shotmsg'),
      shotStage=document.getElementById('shotstage'),
      shotDisp=document.getElementById('shotdisp'),
      shotOpen=false, MAXZ=12;
  var sc=1, tx=0, ty=0, fit=1, nW=0, nH=0;
  var shotDisplays=[], curDisplay=null;   // null = whole desktop; int = one monitor
  function sApply(){ simg.style.transform='translate('+tx+'px,'+ty+'px) scale('+sc+')'; }
  function sClamp(){
    var w=shotStage.clientWidth, h=shotStage.clientHeight, iw=nW*sc, ih=nH*sc;
    tx = iw<=w ? (w-iw)/2 : Math.min(0,Math.max(w-iw,tx));
    ty = ih<=h ? (h-ih)/2 : Math.min(0,Math.max(h-ih,ty));
  }
  function sFit(){
    var w=shotStage.clientWidth, h=shotStage.clientHeight;
    if(!nW||!nH||!w||!h) return;
    fit=Math.min(w/nW,h/nH); sc=fit; tx=(w-nW*sc)/2; ty=(h-nH*sc)/2; sApply();
  }
  function sZoom(cx,cy,f){
    var ns=Math.min(fit*MAXZ,Math.max(fit,sc*f));
    if(ns===sc) return;
    tx=cx-(cx-tx)*(ns/sc); ty=cy-(cy-ty)*(ns/sc); sc=ns; sClamp(); sApply();
  }
  function onDisplays(list){
    shotDisplays = list || [];
    if(curDisplay===null && shotDisplays.length){
      var p=0;
      for(var i=0;i<shotDisplays.length;i++){ if(shotDisplays[i].primary){ p=i; break; } }
      var d=shotDisplays[p];
      curDisplay = (typeof d.index==='number') ? d.index : p;
    }
    if(shotOpen) renderDispChips();
  }
  function renderDispChips(){
    shotDisp.innerHTML='';
    if(shotDisplays.length<2) return;   // only offer a picker when there's a choice
    shotDisplays.forEach(function(d,i){
      var idx=(typeof d.index==='number')?d.index:i;
      var b=document.createElement('button');
      b.className='chip'+(idx===curDisplay?' on':'');
      b.textContent='Display '+(i+1)+(d.primary?' ★':'');
      b.addEventListener('click',function(){
        curDisplay=idx; renderDispChips(); captureCurrent(); });
      shotDisp.appendChild(b);
    });
  }
  function captureCurrent(){
    simg.style.visibility='hidden'; shotmsg.style.display='';
    shotmsg.textContent='Capturing…';
    send(curDisplay===null ? {t:'shot'} : {t:'shot',display:curDisplay});
  }
  function openShot(){
    if(!ready) return;
    shotOpen=true; shotEl.classList.remove('hidden');
    if(!shotDisplays.length) send({t:'displays'});
    renderDispChips(); captureCurrent();
  }
  function closeShot(){
    shotOpen=false; shotEl.classList.add('hidden');
    simg.removeAttribute('src'); nW=nH=0;     // drop the bytes; nothing kept
  }
  function onShot(m){
    if(!shotOpen) return;
    if(m.err){ shotmsg.style.display='';
      shotmsg.textContent='Couldn’t capture the screen.'; return; }
    simg.onload=function(){
      nW=simg.naturalWidth; nH=simg.naturalHeight;
      simg.style.width=nW+'px'; simg.style.height=nH+'px';
      sFit(); simg.style.visibility='visible'; shotmsg.style.display='none';
    };
    simg.src='data:image/png;base64,'+m.img;
  }
  document.getElementById('shotbtn').onclick=openShot;
  document.getElementById('shotclose').onclick=closeShot;
  document.getElementById('shotref').onclick=captureCurrent;
  document.getElementById('shotin').onclick=function(){
    sZoom(shotStage.clientWidth/2,shotStage.clientHeight/2,1.6); };
  document.getElementById('shotout').onclick=function(){
    sZoom(shotStage.clientWidth/2,shotStage.clientHeight/2,1/1.6); };

  // pan (1 finger) + pinch (2 fingers) + double-tap to toggle zoom
  var sp={}, sn=0, sDist=0, lastTap=0, sMoved=false;
  function spList(){ return Object.keys(sp).map(function(k){return sp[k];}); }
  function rectXY(e){ var r=shotStage.getBoundingClientRect();
    return {x:e.clientX-r.left,y:e.clientY-r.top}; }
  shotStage.addEventListener('pointerdown',function(e){
    shotStage.setPointerCapture(e.pointerId);
    var p=rectXY(e); sp[e.pointerId]={x:p.x,y:p.y}; sn++; sMoved=false;
    if(sn===2){ var a=spList(); sDist=Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y); }
    e.preventDefault();
  });
  shotStage.addEventListener('pointermove',function(e){
    var p=sp[e.pointerId]; if(!p) return; var q=rectXY(e);
    if(sn>=2){
      p.x=q.x; p.y=q.y;
      var a=spList(), d=Math.hypot(a[0].x-a[1].x,a[0].y-a[1].y),
          mx=(a[0].x+a[1].x)/2, my=(a[0].y+a[1].y)/2;
      if(sDist>0) sZoom(mx,my,d/sDist);
      sDist=d; sMoved=true;
    } else {
      var dx=q.x-p.x, dy=q.y-p.y; p.x=q.x; p.y=q.y;
      if(Math.abs(dx)>2||Math.abs(dy)>2) sMoved=true;
      tx+=dx; ty+=dy; sClamp(); sApply();
    }
    e.preventDefault();
  });
  function sUp(e){
    if(sp[e.pointerId]){ delete sp[e.pointerId]; sn=Math.max(0,sn-1); }
    if(sn<2) sDist=0;
    if(sn===0 && !sMoved){
      var now=Date.now(), p=rectXY(e);
      if(now-lastTap<300){ if(sc>fit*1.5) sFit(); else sZoom(p.x,p.y,4); lastTap=0; }
      else lastTap=now;
    }
    e.preventDefault();
  }
  shotStage.addEventListener('pointerup',sUp);
  shotStage.addEventListener('pointercancel',sUp);
  window.addEventListener('resize',function(){ if(shotOpen&&nW) sFit(); });
  window.addEventListener('keydown',function(e){
    if(e.key==='Escape'&&shotOpen) closeShot(); });

  // ---- scan-to-connect: the PIN may arrive in the URL fragment (#1234) ----
  // Fragments are never sent to the server; strip it from history immediately
  // so the PIN doesn't linger in the address bar / browser history.
  var hp = (location.hash || '').replace(/^#/, '').trim();
  if (/^\d{3,12}$/.test(hp)) {
    try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
    document.getElementById('pin').value = hp;
    pin = hp;
    connect();
  } else {
    // No PIN in the URL -> reuse the one this device remembered, so a reload or
    // reopened tab reconnects on its own (like the app). Cleared on a wrong PIN.
    var sp = '';
    try { sp = localStorage.getItem('jr_pin') || ''; } catch (e) {}
    if (sp) { document.getElementById('pin').value = sp; pin = sp; connect(); }
  }
})();
</script>
</body>
</html>
"""
