# JawnRemote

Use your phone as a **mouse and keyboard** for a Windows PC over your local Wi-Fi —
a modern replacement for UnifiedRemote's basic input function, built to be shipped
on the Play Store (and later the App Store).

Two parts:

| Part | Folder | Tech | Role |
|------|--------|------|------|
| **PC server** | [`server/`](server/) | Python 3 (zero deps) | Receives input over the network and injects it via the Win32 `SendInput` API |
| **Phone app** | [`app/`](app/) | Flutter (Dart) | Trackpad + keyboard UI; talks to the server over TCP |

The app and server speak a tiny newline-delimited JSON protocol over TCP, with a
PIN handshake for security and UDP broadcast for auto-discovery.

---

## Quick start (testing on your own network)

### 1. Start the PC server
```
cd server
py server.py
```
It prints a banner like:
```
  JawnRemote server  --  'JawnPC'  is running
  In the phone app, connect to one of these addresses:
      10.0.0.210 : 8770
  PIN:  0957
```

### 2. Open the firewall (once, admin)
Windows blocks incoming connections by default — **this is why UnifiedRemote stopped
working on Win11** (your Wi-Fi is set to `Public`). Double-click
[`server/setup_firewall_ADMIN.bat`](server/setup_firewall_ADMIN.bat) (it self-elevates),
or run in an **admin** PowerShell:
```powershell
New-NetFirewallRule -DisplayName "JawnRemote" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8770 -Profile Any
New-NetFirewallRule -DisplayName "JawnRemote (discovery)" -Direction Inbound -Action Allow -Protocol UDP -LocalPort 8770 -Profile Any
```

### 3. Connect from the phone
- Make sure the phone is on the **same Wi-Fi**.
- Open the app. Your PC should appear under **Discovered**; tap it and enter the PIN.
- If discovery doesn't find it, tap **Add PC** and type the IP + PIN shown in the
  server window.

---

## PC server details

- **Requirements:** Windows + Python 3.8+. No `pip install` needed.
- **PIN:** auto-generated and saved in `server/pin.txt`. Override with `--pin 1234`,
  or disable auth for local testing with `--no-auth`.
- **Port:** `8770` by default (`--port`).
- Run `py server/test_client.py` (with the server running) to self-test input injection.

### End-user install (the easy path — no Python, no console)
Ship end users **`JawnRemote-Server-Setup.exe`**: they double-click it, click **Yes** on
one UAC prompt, then Next → Install → Finish. The installer:
- drops a single ~12 MB `JawnRemoteServer.exe` into Program Files (Python bundled in),
- **opens the firewall on all network profiles** (TCP+UDP 8770) — so it works even on a
  "Public" network, the exact thing that breaks UnifiedRemote,
- adds a Start Menu (and optional desktop) shortcut, then launches the app.

The app is a small window showing the PC's address, the PIN, live connection status, and
a "Start automatically when I sign in" toggle. No console, nothing to configure.

### Building the server .exe + installer (developer)
```
pip install pyinstaller
cd server
py -m PyInstaller --noconfirm --onefile --windowed --name JawnRemoteServer ^
   --icon JawnRemoteServer.ico --add-data "JawnRemoteServer.ico;." server_gui.py
cd ..
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\JawnRemote.iss
```
Output: `installer\Output\JawnRemote-Server-Setup.exe`. See [HOSTING.md](HOSTING.md) for
free hosting + the code-signing note (removes the SmartScreen "unknown publisher" warning).

`server.py` (console) and `server_gui.py` (window) share the same core — use the console
one for development: `py server.py`.

---

## Phone app details

- **Framework:** Flutter 3.44+. **Package id:** `com.jawnstoninc.jawnremote`.
  **Display name:** JawnRemote.
- **Source layout:**
  ```
  app/lib/
    main.dart                 app entry + theme
    app_scope.dart            shared services (InheritedWidget)
    models/host.dart          saved/discovered PC
    services/
      remote_client.dart      TCP client, protocol, auto-reconnect
      discovery.dart          UDP discovery
      settings.dart           prefs + saved hosts
    screens/
      connect_screen.dart     pick / add a PC
      remote_screen.dart      status + trackpad + buttons + keyboard
      settings_screen.dart    sensitivity, scroll, etc.
    widgets/
      trackpad.dart           gesture engine
      keyboard_bar.dart       typing + special keys + modifiers
  ```

### Gestures
| Gesture | Action |
|---------|--------|
| One-finger drag | Move cursor |
| One-finger tap | Left click |
| Two-finger tap | Right click |
| Three-finger tap | Middle click |
| Two-finger drag | Scroll |
| Double-tap then drag | Hold left button & drag (select) |

### Build & run (debug)
```
cd app
flutter run                 # on a connected device/emulator
flutter build apk --debug   # produces build/app/outputs/flutter-apk/app-debug.apk
```
Sideload the debug APK to a phone with `adb install -r app-debug.apk` (or just copy it
over and tap it, enabling "install unknown apps").

---

## Play Store release build

1. **Create a signing key** (keep this file safe — losing it means you can't update the app):
   ```
   keytool -genkey -v -keystore %USERPROFILE%\jawnremote-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias jawnremote
   ```
2. **Create `app/android/key.properties`** (do NOT commit it):
   ```
   storePassword=********
   keyPassword=********
   keyAlias=jawnremote
   storeFile=C:/Users/skaki/jawnremote-release.jks
   ```
3. **Wire signing into** `app/android/app/build.gradle.kts` (load `key.properties` and set
   `signingConfigs.release`; point `buildTypes.release.signingConfig` at it). See the
   commented block added there, or the Flutter docs: <https://docs.flutter.dev/deployment/android>.
4. **Build the App Bundle** (Play Store format):
   ```
   cd app
   flutter build appbundle --release   # build/app/outputs/bundle/release/app-release.aab
   ```
5. Upload the `.aab` in the [Play Console](https://play.google.com/console). You'll also
   need: a privacy policy URL, store listing graphics, content rating, and a data-safety
   form (this app collects no personal data; it talks only to your own PC on the LAN).

### iOS later
The `app/ios/` folder is already scaffolded. When ready, build on a Mac with
`flutter build ipa`. The Dart networking (raw `Socket`/UDP) is cross-platform, so the
app logic carries over unchanged.

---

## Protocol reference (TCP, newline-delimited JSON)

Client → server:
```jsonc
{"t":"hello","pin":"0957","name":"Pixel 7"}   // first message; auth
{"t":"m","x":12,"y":-3}                        // relative mouse move
{"t":"click","b":"left"}                       // b: left|right|middle
{"t":"down","b":"left"}  {"t":"up","b":"left"} // press / release (drag)
{"t":"scroll","y":-120,"x":0}                  // wheel units (120 = one notch)
{"t":"text","s":"hello"}                       // type unicode text
{"t":"key","k":"enter","m":["ctrl"]}           // named key + modifiers
{"t":"ping"}
```
Server → client:
```jsonc
{"t":"welcome","ok":true,"server":"JawnPC"}    // or ok:false, err:"bad_pin"
{"t":"pong"}
```
UDP discovery: client broadcasts `{"t":"discover","app":"JawnRemote"}` to port 8770;
server replies `{"t":"server","name":"JawnPC","port":8770}`.

---

## Troubleshooting

- **Can't connect / times out:** the firewall isn't open, or Wi-Fi is `Public`. Run the
  firewall script above (it allows all profiles). Confirm the phone and PC are on the
  **same** network (not a guest/IoT SSID).
- **"Wrong PIN":** check `server/pin.txt` or the server window.
- **Discovery finds nothing, but manual IP works:** the UDP firewall rule is missing, or
  the router blocks broadcast. Manual IP entry is unaffected.
- **Cursor too fast/slow:** Settings → Pointer speed. (Tip: turning off Windows "Enhance
  pointer precision" makes movement perfectly linear.)

---

## Roadmap
- Server: minimize-to-tray + auto-update; code-signed installer (no SmartScreen warning).
- App: media keys & volume, presentation mode, custom buttons, multi-monitor hint.
- Cross-platform server (macOS/Linux input injection) for a wider market.
- iOS release.
