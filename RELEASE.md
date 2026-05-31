# Releasing JawnRemote

## Repo structure (recommended)
Because you're selling this, the source stays private and only the installer is public:

- **`JawnRemote`** (private) — the full source (this repo).
- **`jawnremote-downloads`** (public) — a landing page + GitHub Releases that host the
  installer, giving you a **free public download link** with unlimited bandwidth.

## One-time setup
1. `gh` (GitHub CLI) is installed. Authenticate once:
   ```
   gh auth login
   ```
   Choose **GitHub.com → HTTPS → Login with a web browser**.
2. Publish everything:
   ```
   powershell -ExecutionPolicy Bypass -File tools\publish_github.ps1
   ```
   This creates both repos (if needed), pushes the source, and publishes release
   `v1.0.0` with `JawnRemote-Server-Setup.exe` attached. It prints your public link:
   ```
   https://github.com/GameJawnsInc/jawnremote-downloads/releases/latest/download/JawnRemote-Server-Setup.exe
   ```

## Manual equivalent (if you prefer, or the script hiccups)
```powershell
# from the repo root, after `gh auth login`
gh repo create JawnRemote --private --source . --remote origin --push          # source
gh repo create jawnremote-downloads --public                                    # downloads
gh release create v1.0.0 "installer\Output\JawnRemote-Server-Setup.exe" `
    --repo GameJawnsInc/jawnremote-downloads --title "JawnRemote v1.0.0" `
    --notes "PC server installer."
```

## Cutting a new version later
1. Bump `version:` in `app/pubspec.yaml` and `MyAppVersion` in `installer/JawnRemote.iss`.
2. Rebuild:
   ```
   cd server && py -m PyInstaller --noconfirm --onefile --windowed --name JawnRemoteServer ^
       --icon JawnRemoteServer.ico --add-data "JawnRemoteServer.ico;." server_gui.py
   cd .. && "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\JawnRemote.iss
   cd app && flutter build appbundle --release      # upload this .aab to Play Console
   ```
3. Commit & push the source, then publish the new installer:
   ```
   git add -A && git commit -m "Release vX.Y.Z" && git push
   gh release create vX.Y.Z "installer\Output\JawnRemote-Server-Setup.exe" `
       --repo GameJawnsInc/jawnremote-downloads --title "JawnRemote vX.Y.Z" --notes "..."
   ```
   (Or just re-run `tools\publish_github.ps1` after editing `$Version`.)

## The Play Store side
- `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab`
  (also copied to repo root as `JawnRemote-release.aab`). Upload that in the Play Console.
- Your **upload keystore** is at `C:\Users\skaki\jawnremote-upload-keystore.jks`, and the
  passwords are in `app/android/key.properties` (git-ignored). **Back up both** — and note
  that with Play App Signing you can reset a lost *upload* key via Google support.
