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
- **Full keyboard** (text + special keys + modifier shortcuts).
- **On-screen volume** (up/down/mute) + **hardware volume-rocker capture**.
- **Media transport keys** — play/pause, prev, next, stop. *(UI sends the keys
  the server already maps to VK_MEDIA_*.)*
- **System power controls** — lock, sleep, log off, restart, shut down
  (destructive ones confirm on the phone first). *(New `power` server command.)*
- **Multi-PC basics** — saved hosts + UDP auto-discovery.
- **Local-only / no account / PIN auth** — the trust + privacy model users want.

## 🔜 Next (high demand, good ROI)
1. **Presentation mode** — a dedicated layout: next/prev slide (PageDn/PageUp or
   arrows), F5 start, Esc, B/W to black/white the screen. *Pure key events — the
   server already supports them; it's a Flutter screen.* Big with one segment.
2. **App quick-launch / a few app-remotes** — open YouTube/Netflix/Spotify/VLC/
   Kodi + their media keys. Needs one new `launch` server command (open app/URL).
   A small curated set (not UR's 90+) captures most of the value. Good **paid Pro**
   candidate.
3. **Extended-key polish** — make sure Ctrl/Alt/Win/Esc/F-keys/Tab + shortcuts are
   all one tap and reliably fire (competitors paywall these — keep them free).

## ⏳ Later (power users / niches)
4. **Custom buttons & macros** — user-defined buttons that send keystrokes/launch
   apps. Sticky, loyal audience; UR paywalls it. Bigger UI + a server `exec` path
   (local-trust only). Strong **Pro** feature.
5. **Wake-on-LAN** — phone sends a magic packet to power the PC *on* (when the
   server isn't running). Store the PC's MAC; HTPC crowd wants it.
6. **Multi-PC polish** — rename/reorder saved PCs, per-PC settings.
7. **Landscape / tablet layout** — competitors paywall landscape; free = edge.
8. **Clipboard sync** — send/receive clipboard text (cheap, KDE-Connect parity).

## ❌ Out of scope (off-strategy / heavy)
- **Screen mirroring / remote desktop** — different product; Chrome Remote
  Desktop / VNC / AnyDesk own that. A low-FPS "glance" at most, much later.
- **Voice control** — rarely the reason anyone picks an app.
- **Full file manager / transfer** — heavy; off the lightweight-control core.

---

## Monetization fit
- **Free, ad-free:** mouse, keyboard, volume, **media transport, power controls,
  modifier keys** — exactly what competitors charge for. This is the wedge.
- **One-time "Pro pack" (~$5–15, not a subscription):** presentation mode,
  app-remotes, custom buttons/macros, multi-PC, landscape. Keep the existing
  $1.99 remove-ads, add Pro later. **Never** a second paywall or subscription —
  that's the exact thing users rage about in competitor reviews.

## Engineering north star
Connection **reliability + instant auto-reconnect + dead-simple setup** is the #1
complaint about *every* competitor (including UR). Treat it as a first-class
feature, not polish — it's why people are switching.
