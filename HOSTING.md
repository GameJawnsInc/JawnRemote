# Hosting the download — cheapest options

The **phone app** ships through the Play Store (Google hosts it; your only cost is
the one-time **$25** Google Play developer fee). The only thing *you* host is the
**Windows server installer** — `JawnRemote-Server-Setup.exe`, ~14 MB. It's a small
static file, so hosting can be essentially free.

## TL;DR
- **Start here:** GitHub Releases — free, unlimited bandwidth, zero setup.
- **Branded/own-domain later:** Cloudflare R2 (free egress) + Cloudflare Pages (free site).
- **The actual cost to plan for is a code-signing certificate**, not hosting (see bottom).

---

## 1. GitHub Releases — FREE  ✅ recommended to start
- Make a repo, attach the `.exe` to a Release. (Closed-source is fine: keep code in a
  private repo and attach binaries, or use a small public "downloads-only" repo.)
- Free, **unlimited public download bandwidth**, served over a global CDN (Fastly), versioned.
- Stable "always latest" link for your website's download button:
  `https://github.com/<you>/<repo>/releases/latest/download/JawnRemote-Server-Setup.exe`
- Zero infrastructure, zero cost, reliable. This is the right call for launch.

## 2. Cloudflare R2 + Pages — ~$0, branded
- **R2** object storage has **no egress fees** — you pay only storage (~$0.015/GB-month,
  first 10 GB free). A 14 MB installer is a fraction of a cent per month *no matter how
  many times it's downloaded.*
- Serve it from your own domain (`downloads.yourapp.com`) via an R2 public bucket / Worker.
- Host the marketing page on **Cloudflare Pages** (free static hosting).
- Best when you want everything on your own domain at basically zero cost.

## 3. Also fine / avoid
- **Backblaze B2 + Cloudflare** (Bandwidth Alliance → free egress): similar to R2.
- **Netlify / Vercel / GitHub Pages** free tiers: great for the *site*; for the binary,
  link out to GitHub Releases or R2 (big-file downloads can hit fair-use limits).
- **Avoid** AWS S3 / generic clouds for the download itself — egress (~$0.09/GB) adds up.

---

## The real cost line item: code signing
Right now the installer is **unsigned**, so Windows SmartScreen warns users
("Windows protected your PC — unknown publisher") and they must click
**More info → Run anyway**. For a paid product this hurts trust and conversions.

| Option | ~Cost/yr | Effect |
|--------|---------|--------|
| Unsigned | $0 | Scary SmartScreen prompt; OK for early testing only |
| **OV** code-signing cert | ~$150–300 | Removes "unknown publisher"; SmartScreen trust builds as downloads accumulate |
| **EV** code-signing cert | ~$300–500 | Instant SmartScreen trust (no warning), needs hardware token / cloud HSM |

Sign with `signtool.exe` (Windows SDK) as a post-build step. Recommended before a real
launch; for now, the README documents the "Run anyway" step.

## Later: auto-update (still free)
Ship a tiny `latest.json` (version + download URL) next to the installer on the same
free host; the server app can check it on startup and offer to update. No extra cost.
