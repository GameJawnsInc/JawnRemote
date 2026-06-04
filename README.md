# JawnRemote

Turn your phone — or any device with a web browser — into a **mouse, keyboard, and
remote control** for a Windows PC over your local Wi-Fi.

**Free. No ads, no accounts, no cloud.** Everything stays on your network: the phone
talks straight to a tiny server on your PC, PIN-protected, and nothing ever leaves
your LAN. It's the firewall-friendly replacement for UnifiedRemote's basic input —
the open port is scoped to your own subnet, so it works even on a "Public" Wi-Fi
profile (the exact thing that breaks UnifiedRemote on Windows 11).

Two ways to connect:

- **Android app** — the full-featured client (trackpad gestures, custom macros,
  file transfer, Wake-on-LAN, auto-discovery).
- **Browser remote** — open `http://<pc-ip>:8770/` on *any* device on the Wi-Fi.
  Nothing to install. Scan the QR code in the server window to connect in one tap.

---

## Features

| Feature | App | Browser |
|---|:---:|:---:|
| Trackpad (move, tap, right/middle-click, scroll, drag-select) | ✅ | ✅ |
| Full keyboard — typing, shortcuts (Ctrl+C/V…), F-keys, modifiers | ✅ | ✅ |
| Media & volume keys | ✅ | ✅ |
| Presentation controls (start, next/prev, black, end) | ✅ | ✅ |
| App launcher (your own quick-launch tiles) | ✅ | ✅ |
| Clipboard sync (push/pull text between phone and PC) | ✅ | ✅ |
| **Quick View** — pull a screenshot of the PC, pinch-to-zoom, pick a monitor | ✅ | ✅ |
| Power (lock, sleep, restart, shut down, log off) | ✅ | ✅ |
| Custom macros — buttons that fire keystrokes or launch apps | ✅ | — |
| File transfer (phone ↔ PC) | ✅ | — |
| Wake-on-LAN — turn the PC on from your phone | ✅ | — |
| Auto-discovery (finds your PC on the Wi-Fi) | ✅ | — |
| Browser client — zero install, QR scan-to-connect | — | ✅ |

Nothing is stored in the cloud; Quick View screenshots are never written to disk —
they're streamed once and dropped when you close the viewer.

---

## Install (end users)

Grab the latest **`JawnRemote-Server-Setup.exe`** (PC) and **`JawnRemote.apk`**
(Android) from the [**Releases**](https://github.com/GameJawnsInc/JawnRemote/releases/latest)
page — or from [jawnston.com/jawnremote](https://jawnston.com/jawnremote/).

**PC server (Windows):** run the installer. One UAC prompt, then Next → Install →
Finish. It drops a single self-contained `JawnRemoteServer.exe` (Python bundled in
— no install needed) and opens the firewall for TCP+UDP `8770`, scoped to
`localsubnet` so the port is invisible to the internet. A small window shows your
PC's address, the PIN, and live status.

**Phone:** install the APK (enable "install unknown apps" when prompted), make sure
it's on the same Wi-Fi, tap your PC under **Discovered**, and enter the PIN.

**Browser:** open `http://<pc-ip>:8770/` on any device on the network, or scan the QR
code shown in the server window. Enter the PIN and you're in.

---

## Privacy & security

- **Local-only.** The phone/browser connects directly to your PC over the LAN. There
  is no cloud service, no account, no telemetry. JawnRemote never phones home.
- **PIN handshake** on every connection, with a brute-force lockout after repeated
  bad PINs.
- **Firewall scoped to `localsubnet`** — the port is reachable from your own network
  only, not the internet.
- **Open source.** The whole thing is in this repo — read it, audit it, build it
  yourself. The PC server is ~zero-dependency Python standard library; you can run it
  straight from source with `py server/server.py` if you'd rather not run the `.exe`.
- **SmartScreen note:** the installer isn't code-signed yet, so Windows may show
  "Windows protected your PC / unknown publisher." Click **More info → Run anyway**,
  or build it yourself from source (below).

---

## How it works

| Part | Folder | Tech |
|---|---|---|
| PC server | [`server/`](server/) | Python 3 (standard library only) — injects input via the Win32 `SendInput` API; captures the screen via GDI; serves the browser client over a hand-rolled HTTP/WebSocket on the same port |
| Phone app | [`app/`](app/) | Flutter (Dart) — gesture trackpad, keyboard, and the rest |

The app speaks a tiny newline-delimited JSON protocol over TCP (PIN handshake + UDP
broadcast for auto-discovery). The browser speaks the **same** JSON schema over a
WebSocket multiplexed onto the same port, so both clients share one server with one
firewall rule.

---

## Build from source

### PC server (.exe + installer)
```
pip install pyinstaller
cd server
py -m PyInstaller --noconfirm JawnRemoteServer.spec
cd ..
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\JawnRemote.iss
```
Output: `installer\Output\JawnRemote-Server-Setup.exe`. For development, run the
console server directly — no build needed:
```
cd server
py server.py            # --pin 1234 to set a PIN, --no-auth to disable auth, --port to change port
```

### Android app
```
cd app
flutter run                  # on a connected device/emulator
flutter build apk --release  # build/app/outputs/flutter-apk/app-release.apk
```
Release builds are signed with a local keystore referenced by
`app/android/key.properties` (git-ignored; create your own with `keytool`, e.g.
`storeFile=%USERPROFILE%/jawnremote-release.jks`). Debug builds need no signing.

---

## Protocol reference (TCP / WebSocket, newline-delimited JSON)

Client → server (selected):
```jsonc
{"t":"hello","pin":"0957","name":"Pixel 7"}   // first message; auth
{"t":"m","x":12,"y":-3}                        // relative mouse move
{"t":"click","b":"left"}                       // b: left|right|middle
{"t":"scroll","y":-120}                        // wheel units (120 = one notch)
{"t":"text","s":"hello"}                       // type unicode text
{"t":"key","k":"enter","m":["ctrl"]}           // named key + modifiers
{"t":"power","action":"lock"}                  // lock|sleep|restart|shutdown|logoff
{"t":"launch","target":"vlc.exe"}              // launch an app-list entry
{"t":"clipset","s":"..."}  {"t":"clipget"}     // clipboard sync
{"t":"displays"}                               // list monitors
{"t":"shot","display":0}                       // screenshot (display omitted = whole desktop)
```
Server → client:
```jsonc
{"t":"welcome","ok":true,"server":"JawnPC"}    // or ok:false, err:"bad_pin"
{"t":"clip","s":"..."}                         // clipboard contents
{"t":"displays","list":[{"index":0,"w":1920,"h":1080,"primary":true}, ...]}
{"t":"shot","w":1600,"h":900,"img":"<base64 png>"}
```
UDP discovery: client broadcasts `{"t":"discover","app":"JawnRemote"}` to port 8770;
the server replies with its name and address.

---

## Troubleshooting

- **Can't connect / times out:** the firewall isn't open, or your Wi-Fi is `Public`.
  The installer opens the firewall for all profiles; if you're running from source,
  add the rule manually (TCP+UDP 8770) or run `server/setup_firewall_ADMIN.bat`.
  Make sure phone and PC are on the **same** network (not a guest/IoT SSID).
- **"Wrong PIN":** check the PIN in the server window (`server/pin.txt`).
- **Discovery finds nothing, but manual IP works:** the UDP rule is missing or the
  router blocks broadcast. Tap **Add PC** and type the IP shown in the server window.
- **Cursor too fast/slow:** Settings → Pointer speed. (Turning off Windows "Enhance
  pointer precision" makes movement perfectly linear.)

---

## License

[MIT](LICENSE) © Jawnston Inc.
