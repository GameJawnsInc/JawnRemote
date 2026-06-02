# Roadmap — Features (becoming the Unified Remote replacement)

Based on what Unified Remote "refugees" and this category's users actually ask
for (reviews, Reddit, AlternativeTo, UR's own feature list). The strategic edge
isn't a single feature — it's shipping the stuff competitors **paywall** (media,
power, modifier keys) for **free + ad-free**, while keeping the **local-only,
no-account** positioning. Reliability/auto-reconnect is itself a top "feature."

Legend: ✅ done · 🔜 next · ⏳ later · ❌ out of scope

---

## ✅ Done
- **Trackpad mouse** (move, left/middle/right, scroll, drag).
- **Full keyboard** — text + one-tap **modifier/F-key/nav shortcuts** (Ctrl/Alt/
  Win, Esc, Tab, F1–F12, arrows, Home/End/PgUp/PgDn, Copy/Cut/Paste/Undo/Redo/
  Select-all/Alt+Tab).
- **On-screen volume** (up/down/mute) + **hardware volume-rocker capture**.
- **Media transport keys** — play/pause, prev, next, stop.
- **System power controls** — lock, sleep, log off, restart, shut down
  (destructive ones confirm on the phone first). *(`power` server command.)*
- **Presentation mode** — dedicated layout: next/prev slide, F5 start, Esc,
  black/white screen, jump to first/last.
- **App launcher (desktop-managed)** — a quick-launch grid the phone fetches from
  the server; add/edit/reorder apps & URLs in the server window. *(`launch` +
  `getapps` server commands.)*
- **Wake-on-LAN** — phone learns the PC's MAC on connect, later sends a magic
  packet to power it on.
- **Portrait + landscape** — both orientations, overflow-safe.
- **Multi-PC basics** — saved hosts + UDP auto-discovery.
- **Trust & privacy** — local-only, no account, PIN auth, **LAN-scoped firewall**,
  **non-LAN connection refusal**, **brute-force lockout**, **fully free & ad-free**.

## 🔜 Next (high demand, good ROI)
1. **Rock-solid reconnect** — the engineering north star (below). Auto-reconnect
   exists; make it instant + invisible with an unmistakable connection state.
   It's the #1 complaint about every competitor — treat it as a headline feature.
2. **Custom buttons & macros** — user-defined buttons that fire keystrokes or
   launch apps/sequences. Builds straight on the desktop-managed app list we
   already ship; add a server `exec`/sequence path (local-trust only). Sticky,
   loyal audience; UR paywalls it. Strongest **Pro** candidate.
3. **Multi-PC polish** — rename/reorder saved PCs, per-PC settings, quick switch.
4. **Clipboard sync** — send/receive clipboard text (cheap, KDE-Connect parity).

## ⏳ Later (power users / niches)
5. **Tablet/big-screen layout** — landscape already works; this makes the controls
   shine on tablets (e.g. side-by-side trackpad + button cluster).
6. **Per-PC profiles** — remembered pointer speed / scroll / layout per saved PC.

## ❌ Out of scope (off-strategy / heavy)
- **Screen mirroring / remote desktop** — different product; Chrome Remote
  Desktop / VNC / AnyDesk own that. A low-FPS "glance" at most, much later.
- **Voice control** — rarely the reason anyone picks an app.
- **Full file manager / transfer** — heavy; off the lightweight-control core.

---

## Monetization fit
- **Shipping 100% free & ad-free today** — ads are disabled (no SDK / no Ad-ID)
  and the app gives away everything competitors paywall (media, power, modifiers,
  presentation, app-launch, WoL, landscape). That generosity *is* the wedge.
- **Optional one-time "Pro pack" later (~$5–15, never a subscription):** the
  heavier power-user tier — custom buttons/macros above all. The dormant
  `remove_ads` IAP scaffolding can be repurposed. **Never** a subscription —
  that's the exact thing users rage about in competitor reviews.

## Engineering north star
Connection **reliability + instant auto-reconnect + dead-simple setup** is the #1
complaint about *every* competitor (including UR). Treat it as a first-class
feature, not polish — it's why people are switching.
