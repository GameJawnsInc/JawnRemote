# Roadmap — Forming an LLC in Scranton, Pennsylvania

Current as of 2026 (Lackawanna County). For a single-member LLC running a
small software/app business.

> ⚠️ **Informational only — not legal or tax advice.** The filing mechanics are
> straightforward, but the tax items (sales tax on apps, S-corp election, local
> earned-income tax) genuinely benefit from a **PA CPA**, and anything unusual
> from a **PA attorney**. Items flagged below are where that matters most.

---

## Naming note (do this first)
Your app/installer publisher says **"Jawnston Inc."** A Pennsylvania **LLC's name
must end in "LLC" / "L.L.C." / "Limited Liability Company"** — it **cannot** use
"Inc." (that's for a corporation). So:
- Register the entity as **"Jawnston LLC"** (check availability in the PA name search).
- Keep **"JawnRemote"** as the product/app name (and the **Jawnston LLC** as developer/publisher).
- If you want to market the *company* as something other than "Jawnston LLC", register a **Fictitious Name (DBA)** — see step 7.
- Update the "Jawnston Inc." string in the app + Inno installer to match the real entity once formed.

---

## Step 1 — Pick + check the name
- [ ] Search name availability on the PA **Business Filing Services** site (free).
- [ ] Confirm a matching **jawnston.com** is already yours (it is) — good.

## Step 2 — Registered office (PA's term for the address on record)
PA requires a **physical PA street address** that can receive legal mail (no PO boxes), and **it becomes public record**.
- [ ] Either use a **PA street address** you control, **or** — to keep your **home address private** — pay a **Commercial Registered Office Provider (CROP)** (~$50–$150/yr). Recommended for a home-based business.

## Step 3 — File the formation documents ($125, ~5–7 business days)
- [ ] File the **Certificate of Organization — Domestic LLC (form DSCB:15-8821)** **together with** the **New Entity Docketing Statement (DSCB:15-134A)**.
- [ ] **Fee: $125** (one filing covers both; docketing statement has no separate fee).
- [ ] File online via the **PA Business One-Stop Hub** (`file.dos.pa.gov`, create a Keystone Login). Optional **expedited** service costs extra.

## Step 4 — Get an EIN (free, ~15 min)
- [ ] After the LLC is approved, get an **EIN** from the **IRS online** (free, immediate). Avoid sites that charge for it.
- [ ] A single-member LLC *can* use your SSN, but you'll want the EIN to **open a business bank account** and keep finances clean.

## Step 5 — Operating Agreement (not required, but do it)
- [ ] PA doesn't require one, but a written **single-member Operating Agreement** helps **reinforce the liability shield** (shows the LLC is a real, separate entity) and documents management/succession. A solid template is fine for a solo SMLLC.

## Step 6 — Separate the money (this is what actually protects you)
- [ ] Open a **business bank account** in the LLC's name (EIN + formation docs).
- [ ] Run **all** app income (Play payouts, AdMob, website sales) and expenses through it. Commingling personal/business funds is the fastest way to lose the liability protection you paid for.

## Step 7 — Fictitious Name / DBA (only if needed)
- [ ] Only if you operate under a name **different** from "Jawnston LLC": file **Application for Registration of Fictitious Name (DSCB:54-311)**, **$70**.
- [ ] Good news: an **LLC does not need the newspaper publication** that sole proprietors do.

## Step 8 — Federal BOI report (currently NOT required — but watch it)
- [ ] As of 2026, a **U.S.-formed LLC is exempt** from the FinCEN **Beneficial Ownership Information** report (interim final rule, Mar 2025 — only *foreign* entities must file).
- [ ] ⚠️ This is an **interim** rule FinCEN intends to finalize; the requirement for domestic LLCs **could come back**. **Re-check fincen.gov/boi** before assuming you owe nothing, especially if ownership isn't 100% U.S.-individual.

---

## Ongoing compliance (don't forget these)

### ⭐ PA Annual Report — NEW, easy to miss
- **Form DSCB:15-146, $7/year**, due **by September 30** (the LLC group's deadline).
- Brand new under **Act 122 of 2022** — **started 2025**, replaced the old decennial report.
- First report is due the **year after** you form (form in 2026 → first report 2027).
- **Penalty teeth start with 2027 reports:** miss it and you face **administrative dissolution ~6 months after the due date** (2025/2026 reports have a grace period). **Calendar it every year by Sept 30.**

### Taxes (CPA territory — flagged)
- **PA Personal Income Tax: flat 3.07%.** A single-member LLC is a **pass-through / disregarded entity** — no PA entity-level income tax; profit flows to your **PA-40**.
- **Scranton Local Services Tax (LST): $156/yr** if you work in the city and earn over **$15,600** from in-city sources (file an exemption certificate if under). Paid quarterly.
- **Scranton Business Privilege & Mercantile Tax: $0 currently** — the city **suspended current-year BPT/MT in 2023** (only collects old delinquencies). Confirm it still applies to you.
- **Local Earned Income Tax** on net profits (administered by **Berkheimer** locally) — **ask a CPA** how a self-employed LLC owner files this.
- **PA Sales Tax — important & nuanced:** PA treats **"canned" software, apps, and digital products as TAXABLE (6%; Lackawanna has no add-on)**. **BUT** when you sell through **Google Play / the App Store**, the **marketplace facilitator usually collects/remits the tax for you** — so you may owe nothing extra on store sales, while **direct website sales** could be different. **Get a CPA's read before registering or collecting.** If you do need to collect, register via **myPATH** (free).
- **Consider an S-corp election later** (Form 2553) once profitable — can cut self-employment tax, but adds payroll/complexity. **CPA decision.**

---

## Cost cheat-sheet (one software SMLLC)
| Item | Amount | When |
|---|---|---|
| Certificate of Organization + Docketing Statement | **$125** | once |
| EIN (IRS) | **$0** | once |
| Operating Agreement (DIY/template) | **$0** | once |
| Fictitious Name / DBA (*if used*) | **$70** | once |
| CROP (*optional privacy*) | ~$50–150 | yearly |
| **PA Annual Report (DSCB:15-146)** | **$7** | **yearly by Sept 30** |
| Scranton LST (*if working in-city, >$15,600*) | **$156** | yearly (quarterly) |
| Scranton BPT/MT | **$0** (suspended) | — |

**Realistic startup cost: ~$125–$200** to be fully formed and operating, plus ~$7/yr to stay in good standing.

## Order of operations
Name check → registered office (CROP if private) → **file DSCB:15-8821 + 15-134A ($125)** → **EIN** → operating agreement → **business bank account** → (DBA if needed) → update "Jawnston Inc." → "Jawnston LLC" in the app/installer → calendar the **Sept 30 annual report**.

## Official references
- PA LLC overview: https://www.pa.gov/agencies/dos/programs/business/types-of-filings-and-registrations/pennsylvania-limited-liability-company
- Online filing hub: https://file.dos.pa.gov
- PA Annual Report: https://www.pa.gov/agencies/dos/programs/business/types-of-filings-and-registrations/annual-reports
- Commercial Registered Office Providers: https://www.pa.gov/agencies/dos/programs/business/information-services/commercial-registered-office-providers
- IRS EIN (free): https://www.irs.gov/businesses/small-businesses-self-employed/get-an-employer-identification-number
- FinCEN BOI status: https://www.fincen.gov/boi
- PA sales tax on software/digital goods: https://www.pa.gov/agencies/revenue/resources/tax-types-and-information/sales-use-and-hotel-occupancy-tax/canned-computer-software-digital-goods
- Scranton Single Tax Office (LST, BPT/MT): https://scrantontaxoffice.org
