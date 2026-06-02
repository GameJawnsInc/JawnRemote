# Roadmap — Publishing JawnRemote on the Google Play Store

Current as of 2026. A **free, ad-free** app (the AdMob + "Remove ads" IAP code
ships **disabled** as of 1.5.1 — see *Data safety & privacy* below). Verify the
live numbers as you go (links at the bottom); Google changes these.

---

## Data safety & privacy — current posture (LOCKED IN, app 1.5.1)

**The app is ad-free with zero data collection.** Ads are disabled (no Google
Mobile Ads init, no banner, no Advertising ID read), there's no analytics SDK,
no account/sign-in, and every connection is phone↔PC on the local network —
PIN-gated, with the server firewall scoped to `remoteip=localsubnet`. The only
Android permission requested is `INTERNET` (for the LAN socket).

**Play Console answers — fill these exactly:**
- **Data safety → Data collected:** **None** ("Does your app collect or share any
  of the required user data types?" → **No**).
- **Data safety → Data shared:** **None.**
- **Advertising ID:** **No** — the ads SDK is not initialized in this build.
- **Content rating (IARC) → Contains ads:** **No.**
- **Store presence → Contains ads:** **No.**
- **Privacy policy:** `jawnston.com/jawnremote/privacy.html` (already linked).

Keep these in sync with the privacy policy **and** the website's *Security &
privacy* section — a data-safety ⇄ privacy-policy mismatch is the #1 rejection
cause, and "No data collected" is the easiest possible version to keep matching.

> ⚠️ **This flips if you re-enable ads** (set `kAdsEnabled = true` / ship AdMob):
> declare **Device or other IDs → Advertising ID**, mark **Contains ads = Yes**,
> swap in **real AdMob unit IDs**, and re-link AdMob after launch. The dormant
> `remove_ads` IAP + AdMob code remain in the build for exactly that path.

---

## The one decision that changes everything: Personal vs Organization account

You pick this once at signup and it's hard to change later.

| | **Personal** | **Organization** |
|---|---|---|
| Identity proof | Gov ID + address | Gov ID + **D-U-N-S number** + business doc + **public website** |
| Closed-testing gauntlet (below) | **Required** | **Exempt** (verified org accounts) |
| Best when | No legal entity yet | You have an LLC |

**Strong recommendation:** if you form the **Jawnston LLC** (see the LLC roadmap), register the Play account as an **Organization**. A free **D-U-N-S number** from Dun & Bradstreet (takes days–weeks) + your existing **jawnston.com** site is all you need, and it **skips the 12-tester/14-day closed-testing requirement** entirely. That alone is worth doing the LLC first.

> The publisher string in your app/installer currently says "Jawnston Inc." — a PA **LLC must end in "LLC"** (you can't use "Inc."). Plan to register as **Jawnston LLC** and keep "JawnRemote" as the product name. Reconcile the publisher string before you submit.

---

## Phase 0 — Account setup (~1 day, + D-U-N-S wait if org)
- [ ] Create a Google Play Console account — **$25 one-time fee** (not annual).
- [ ] Choose **Organization** (recommended) or Personal.
- [ ] Complete **identity verification** (legal name, address, phone). Org accounts: get a **free D-U-N-S** at dnb.com first; list jawnston.com.
- [ ] Don't miss your assigned **verification deadline** — unverified profiles get removed from Play. You can start up to 60 days early and request a 90-day extension.

## Phase 1 — Prepare the build
- [ ] **Target API level 36 (Android 16)** — required for new apps/updates from **Aug 31, 2026**. Set `targetSdk` accordingly (Flutter: `flutter.targetSdkVersion`/explicit 36) and re-test.
- [ ] Ship an **Android App Bundle (.aab)** — monolithic APKs are not accepted for new apps. (You already build `JawnRemote-release.aab`.)
- [ ] **Play App Signing**: upload with your **upload key**; Google holds the **app signing key** and signs what users download.
  - ⚠️ This is exactly why your **website APK (upload-key-signed) and the Play version (app-signing-key-signed) can't update over each other** — different signatures. Fine to keep both channels; just know users must pick one.
- [ ] **Ad-free build: skip.** *Only if you re-enable ads:* swap **AdMob test IDs for real ad unit IDs** (app ID in `AndroidManifest.xml` + banner unit) — shipping test IDs to production violates AdMob policy.
- [ ] Confirm **Play Billing Library 8+** (mandatory for new submissions since Aug 31, 2025; `in_app_purchase` should pull a compatible version — verify).

## Phase 2 — Store listing + compliance (the rejection magnets)
- [ ] **Assets** (you already generated most): app **icon 512×512** PNG; **feature graphic 1024×500** (no transparency); **≥2 phone screenshots** (up to 8); **title** ≤30 chars; **short description** ≤80; **full description** ≤4000.
- [ ] **Privacy policy URL** — required. You have `jawnston.com/jawnremote/privacy.html`. ✅
- [ ] **Data safety form** — declare **No data collected / No data shared** (ad-free build; exact answers in *Data safety & privacy* above). **This must match your privacy policy** — the #1 rejection cause is a data-safety ⇄ privacy-policy mismatch.
- [ ] **Content rating** — complete the **IARC questionnaire**; answer **contains ads = No** (ad-free build). No rating = can't publish.
- [ ] Store presence: leave **"Contains ads" = No** (ad-free build).

## Phase 3 — Monetization wiring
> **Ad-free build: this whole phase is dormant.** Do it only when/if you re-enable ads. The `remove_ads` product and AdMob code stay in the app for that day.
- [ ] Create the **in-app product**: Monetize → Products → In-app products → **one-time / managed product**, **Product ID `remove_ads`** (must match the app code; immutable once set).
- [ ] After the app is **live**, **link your AdMob app to the Play listing** (AdMob → Apps → link; you can't link an unpublished app — wait 24–48 h after publishing).

## Phase 4 — Release (expect TWO review gates if Personal)
- [ ] **Personal account only:** run a **Closed testing** track → get **≥12 testers opted in for ≥14 consecutive days** → **Apply for production** (Google reviews this). *(Org accounts skip this.)*
- [ ] Submit to **production**. New-account first reviews commonly take **up to ~7 days** — budget a week+.
- [ ] **Internal testing** track first (instant, just you) to sanity-check the store build before any of the above.

## Top rejection reasons to pre-empt
1. Data safety form doesn't match privacy policy (your build is **ad-free → declare "No data collected"**; don't declare an Advertising ID you no longer use).
2. Missing/invalid privacy policy URL.
3. No content rating.
4. Unjustified/sensitive permissions (you only use INTERNET — clean).
5. App crashes on launch or broken IAP (you fixed the R8/WorkManager crash — keep an eye on release builds).
6. Wrong target API or uploading an APK instead of an AAB.

## Fast path summary
Form **Jawnston LLC** → get **D-U-N-S** → **Organization** Play account ($25) → build **API 36 AAB** (ad-free) → listing + **data safety ("No data collected")** + privacy URL + IARC rating (**contains ads = No**) → **internal test → production** (no closed-testing gauntlet as an org).

## Official references
- Get started / $25 fee: https://support.google.com/googleplay/android-developer/answer/6112435
- Identity verification & deadlines: https://support.google.com/googleplay/android-developer/answer/10841920
- Closed-testing requirement (12 testers/14 days): https://support.google.com/googleplay/android-developer/answer/14151465
- Target API requirement: https://developer.android.com/google/play/requirements/target-sdk
- Play App Signing: https://support.google.com/googleplay/android-developer/answer/9842756
- Listing asset specs: https://support.google.com/googleplay/android-developer/answer/9866151
- Content ratings (IARC): https://support.google.com/googleplay/android-developer/answer/9898843
- AdMob data-safety disclosure: https://developers.google.com/admob/android/privacy/play-data-disclosure
- Create an in-app product: https://support.google.com/googleplay/android-developer/answer/1153481
- Play Billing integration: https://developer.android.com/google/play/billing/integrate
