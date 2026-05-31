# JawnRemote — Play Store listing (ready to paste)

Package: `com.jawnstoninc.jawnremote` · Developer: Jawnston Inc. · Category: **Tools**

---

## Title  (max 30)
```
JawnRemote: Mouse & Keyboard
```
(28 chars. Brand-only alt: `JawnRemote`.)

## Short description  (max 80)
```
Your phone as a wireless mouse, keyboard & air-mouse for your Windows PC.
```
(73 chars.)

## Full description  (max 4000)
```
JawnRemote turns your phone into a wireless mouse and keyboard for your Windows PC — over your own Wi-Fi, with no cables and no account.

Lost the use of UnifiedRemote on Windows 11? JawnRemote is the simple, reliable replacement: install a tiny free server on your PC, open the app, and your computer shows up automatically. Tap to connect and you're driving your desktop from the couch.

WHAT YOU CAN DO
• Trackpad — drag to move, tap to click, two-finger tap to right-click, two-finger drag to scroll, double-tap-and-drag to select.
• Full keyboard — type straight to your PC, with arrows, Esc, Tab, Backspace, Enter, and shortcuts like Ctrl+C, Alt+Tab and the Windows key.
• Air mouse — point your phone like a laser and the cursor follows, using the gyroscope. Great for presentations and the living room.
• Mouse buttons — dedicated left, middle and right click.

SET UP IN TWO MINUTES
1. On your PC, download the free JawnRemote server (link below) and run the one-click installer — it even opens the Windows Firewall for you.
2. Install this app and put your phone on the same Wi-Fi network.
3. Open the app, tap your PC, and enter the PIN it shows. Done.

Get the free PC server: https://jawnston.com/jawnremote

PRIVATE BY DESIGN
JawnRemote talks directly to your own PC on your local network — no cloud, no sign-in, no account. A PIN pairs your phone to your PC so nobody else on the Wi-Fi can take over.

FREE — OR REMOVE ADS
JawnRemote is free, supported by a single banner ad on the connect screen (never on the trackpad). Prefer it clean? A one-time $1.99 in-app purchase removes ads forever. No subscriptions.

REQUIREMENTS
• A Windows PC running the free JawnRemote server.
• Your phone and PC on the same Wi-Fi network.
• (macOS and Linux servers are on the roadmap.)

Made by Jawnston Inc.
```

## What's new  (max 500) — first release
```
First release of JawnRemote!
• Trackpad: move, click, scroll, drag
• Full keyboard with shortcuts (Ctrl+C, Alt+Tab, Win…)
• Air-mouse: point your phone like a laser (gyroscope)
• Auto-discovers your PC on Wi-Fi; PIN-secured
• Free, with a one-time $1.99 option to remove ads
Questions or ideas? gamejawnsinc@gmail.com
```

---

## "Contains ads"
Set **Yes** (app uses Google AdMob).

## In-app products
One managed product: id `remove_ads`, **$1.99**, "Remove ads".

---

## Data safety form  (IMPORTANT — the app uses AdMob)
The app itself collects nothing and has no account, BUT the **Google AdMob** SDK
collects the Advertising ID (and basic diagnostics) to serve ads. You must declare
this — do **not** answer "no data collected".

**Does your app collect or share user data?** → **Yes**

Declare these (all collected by the ads SDK, not by you):

| Data type | Collected | Shared | Purpose | Linked to identity? |
|-----------|-----------|--------|---------|---------------------|
| Device or other IDs (Advertising ID) | Yes | Yes | Advertising/marketing | No |
| App info & performance (crash logs, diagnostics) | Yes | No | Analytics, app functionality | No |

- **Location:** Not collected (the app requests no location permission).
- **Personal info / messages / photos / contacts / files:** None.
- **Saved PC connections (IP + PIN)** stay **on the device only** — not transmitted to
  you, so they are NOT "collected" for the form.
- Security: **Data is encrypted in transit** = Yes. **Users can request deletion** =
  the Advertising ID can be reset/cleared by the user in Android settings.
- This matches Google's published AdMob data-disclosure guidance. (Pro/ad-free users
  generate no ad data, but you still declare for the app as shipped.)

**Advertising ID:** the app includes the `AD_ID` permission (added automatically by the
ads SDK). In Play Console → App content → Advertising ID, answer **Yes, uses advertising
ID**, purpose **Advertising or marketing**.

---

## Content rating questionnaire (IARC) → expect "Everyone / PEGI 3"
- App category: **Utility / Productivity / Communication → Utility**
- Violence, scary content: **No**
- Sexual/nudity: **No**
- Profanity / crude humor: **No**
- Controlled substances (drugs/alcohol/tobacco): **No**
- Gambling (real or simulated): **No**
- Users can interact / communicate with each other: **No** (connects to your own PC, not other users)
- Shares user's location with other users: **No**
- User-generated content: **No**
- Does the app offer digital purchases: **Yes** (the $1.99 Remove Ads)

---

## Privacy policy URL  (REQUIRED because of ads)
Deploy `webpage/privacy.html` and use:
```
https://jawnston.com/jawnremote/privacy.html
```
(`deploy-site.ps1` now uploads it alongside the landing page.)

## Contact email
```
gamejawnsinc@gmail.com
```

---

## Required graphics (in `play/`)
- **App icon:** `play/icon-512.png` (512×512) ✓ generated
- **Feature graphic:** `play/feature-graphic-1024x500.png` (1024×500) ✓ generated
- **Phone screenshots:** 2–8, min 320 px, 16:9 or 9:16. Good candidates from `_shots/`:
  the trackpad screen, the Air-mouse screen, the keyboard, and the connect screen.
  TIP: grab clean ones from a **Pro (ad-free)** build or a real device so there's no
  "Test Ad" placeholder, and ideally connected to a real PC (green dot).
- (Optional) 7-inch / 10-inch tablet screenshots if you list tablet support.

## Pre-launch checklist
1. Swap AdMob **test IDs** for real ones (see README → Monetization).
2. Create the `remove_ads` $1.99 product in Play Console.
3. Deploy the site + privacy policy (`webpage/deploy-site.ps1`) and the installer
   (`webpage/deploy-installer.ps1`).
4. Upload the **AAB** (`JawnRemote-release.aab`), fill this listing, complete Data
   safety + content rating, set Contains ads = Yes, add the privacy URL.
5. Roll out to **Internal testing** first (the only way to test the IAP).
```
