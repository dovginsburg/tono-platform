# Tono — Project Brief for Review

**What I'm looking for:** ideas on features/UX I might be missing, checks on the
monetization strategy, and a sanity-check on the paywall copy and positioning.

---

## What it is

An iOS keyboard extension + companion app that acts as a **pre-send communication
coach**. The user drafts a message in any app, switches to the Tono keyboard, taps
**Coach**, and gets:

- A **risk badge** (Low / Medium / High) — how this message is likely to land
- **4 rewrites** on different axes: Warmer · Clearer · Funnier · Safer
- One-tap to insert the chosen rewrite back into the original text field

**Core insight:** the 8-second window before hitting Send is universal, daily, and
almost completely unserved. Grammarly fixes grammar. Yoodli does speech roleplay.
Nothing sits in the keyboard at the moment of decision.

**Tagline:** *Say what you mean. Land how you intend.*

**Beachhead:** neurodivergent adults (ADHD, autism-spectrum) navigating social
nuance — highest pain-per-dollar, strong organic community, low sales friction.

---

## What's been built (full feature inventory)

### iOS Keyboard Extension
- QWERTY layout with **Coach** button; draft strip shows text pulled from host app
- **Results view:** risk badge, perception summary, flags, 4 rewrite chips with rationale
- **Risk delta badge** on each chip showing before→after risk level change (e.g. High→Low)
- **Thread context strip:** "Paste thread for context" so the LLM understands prior messages
- **Per-recipient chip strip (Pro):** horizontal scroll of saved recipients; selecting one
  routes the analysis with that person's voice hint (`"prefers formal; no humor"`) and
  boosts their preferred safer axis to top
- **StyleMemory re-ranking (Pro):** rewrite axes re-ordered by the user's historical tap
  pattern; `"Ranked for your style"` or `"For Boss: leaning warmer"` hint shown
- **Offline fallback:** on network failure, falls back to a local mock analyzer
- **Limit-hit copy:** "Tono can remember how you talk to each person and get better every
  time. Unlock the full coach." (coaching framing, not rewrite-count framing)
- **History:** last 5 coach sessions, tap to re-open any result

### Companion App (4 tabs)
**Coach tab (HomeView)**
- Setup walkthrough: enable keyboard → grant Full Access → switch to Tono
- "You're all set" card once keyboard loads
- Footer: StoreKit-backed Pro pricing with no hard-coded UI prices

**Playground tab (PlaygroundView)**
- In-app coaching without the keyboard (for testing / onboarding)

**This Week tab (DigestView)**
- Weekly coaching report: rewrites count, active days, go-to axis, axis breakdown bars
- **Week-over-week trend** per axis: "↑ 18% more often than last week" (requires ≥5pp delta)
- **Streak card** at 5+ active days: flame icon, "X-day coaching streak"
- Free users see **DigestProTeaser**: blurred example breakdown, "Unlock the full coach →"

**Settings tab**
- Account status, daily usage counter
- Preferred voice (e.g. "direct, warm, terse")
- Memory section → MemoryView
- Feature toggles (thread context, weekly digest, risk delta, memory inference)
- Recipient management (add manually or import from Contacts)
- Axis toggles
- Plan section: Free vs Pro, upgrade button, promo code redemption, manage subscription
- **PaywallView** (StoreKit 2, annual-first):
  - Header: "Your personal coach / Tono gets better the more you use it."
  - Feature lines: remembers how you write to each person · ranks rewrites by your style
    · per-recipient coaching hints · weekly tone report · unlimited rewrites
  - Annual: $39.99/yr · eligible 7-day free trial
  - Monthly: $3.99/mo · eligible 7-day free trial
  - Restore purchases link

### Memory (MemoryView) — Pro only
- On-device learned facts (inferred from rewrite choices + manual additions)
- Sent as context hints with each rewrite request
- Categories: profile, style, relationships
- Pro users: full fact list with swipe-to-delete, "Learned" vs "You added this" badges
- Free users: **MemoryProTeaser** — blurred example facts, "Tono learns how you communicate",
  "Unlock memory →" CTA

### WidgetKit
- Small widget: today's usage count + plan
- Medium widget: usage + last perception line
- Lock-screen accessory widget: compact usage
- Refreshes hourly; Pro users show "Pro" instead of N/10

### Slack Integration (Backend)
- `/tono <draft>` slash command; supports `reply: <prior> // <draft>` for thread context
- Block Kit results: axis buttons, risk level, risk delta badge
- Per-user sliding-window rate limiting (10 req/min, env-configurable)

### Backend (FastAPI + SQLite)
- `/v1/register`, `/v1/me`, `/api/analyze`, `/v1/digest`, `/v1/features`, `/v1/checkout`,
  `/v1/portal`, `/v1/coupon/redeem`
- Keychain-stored bearer tokens; device registration on first launch
- Stripe for web checkout; StoreKit 2 for iOS IAP
- Feature flags per device, user-toggleable via `/v1/features/{flag}`
- Weekly digest: current week (0–7 days) + prior week (7–14 days) axis breakdown
- Railway deployment config ready (`railway.toml`, `Dockerfile`, `/data` volume)
- 47/47 backend tests passing

---

## Architecture decisions worth reviewing

**Server-side LLM keys.** The app has no API key on device. Every analysis goes through
`https://api.tonoit.com/api/analyze`. This keeps keys safe and lets
us enforce rate limits and track usage per device.

**Pro detection dual-path.** The keyboard extension is a separate process and can't use
StoreKit. Pro state flows from: StoreKit purchase → `TonePreferences.proUnlocked` in
App Group UserDefaults → keyboard extension reads it. Backend `me.isPro` is the
authoritative source; both must agree for full access.

**Feature flags.** Backend `/v1/features` returns a dict cached in App Group defaults.
Each flag has a hardcoded fallback. Pro-required flags (`memoryInference`,
`memoryContextHints`, `weeklyDigest`, `customAxes`) return false for free users
regardless of the backend dict.

**StyleMemory + RecipientMemory.** On-device only. `StyleMemory.recordTap(axis:, recipientId:)`
accumulates tap weights per axis per recipient. `StyleMemory.sorted(axes, recipientId:)`
returns re-ranked axes (falls back to global if no recipient-specific history). Never
sent to the server — the server only sees the ordered `axes` array in the request.

**Keychain sharing.** App and keyboard extension share secrets (`apiToken`, `deviceID`,
`apiKey`) via a Keychain access group. Team ID placeholder `XXXXXXXXXX` must be replaced
in `SharedKeychain.swift:16` before signing. Legacy UserDefaults secrets are migrated
to Keychain on first run.

---

## Monetization strategy

**Pro ($3.99/mo or $39.99/yr):**
- Unlimited rewrites
- StyleMemory re-ranking ("Ranked for your style")
- Per-recipient coaching (chip strip + per-recipient StyleMemory)
- Memory facts (MemoryView)
- Weekly digest (DigestView)
- All surfaces (future: macOS, Android, Slack Pro)

**Soft paywalls** (not hard blocks):
- Free users hitting the daily limit see coaching/memory copy, not just "limit reached"
- DigestView shows DigestProTeaser — blurred real-looking breakdown
- MemoryView shows MemoryProTeaser — blurred example facts
- Both teasers have a "Unlock" CTA that opens PaywallView

**Annual-first design:** yearly plan listed first and highlighted in purple.
StoreKit controls localized prices and account-specific trial eligibility.

**Approved release contract:** eligible users receive a real 7-day trial, then
$3.99/month or $39.99/year. Active UI prices come from StoreKit.

---

## Open questions for your review

1. **Paywall copy — does the coaching/memory framing land?** The bet is that "Tono
   remembers how you write to each person" converts better than "unlimited rewrites."
   Is there a clearer/stronger headline?

2. **The "This Week" tab — right placement?** Promoted from buried-in-Settings to a
   top-level tab. For free users it's a teaser. Does this feel like a natural
   retention surface or a paywall nag?

3. **Beachhead validity — ND adults first?** The SCOPE.md makes a detailed case for
   neurodivergent adults as the highest pain-per-dollar beachhead. Do you agree with
   the sequencing (ND → B2B managers → general), or is there a better first wedge?

4. **StyleMemory UX — "For Boss: leaning warmer" vs "Ranked for your style."**
   Does the per-recipient hint add clarity or complexity? Is there a better way to
   surface that the ranking is personalized?

5. **Missing features?** What's obviously absent for a v1 that would matter to the
   target user (ND adult, 25–45, heavy texter)?

6. **Pricing contract.** $3.99/mo or $39.99/yr with an eligibility-gated 7-day trial.

7. **App Store risk.** Apple is known to scrutinize keyboards that send data off-device.
   The Full Access requirement is disclosed; the privacy policy covers this. Any other
   review risks to flag?
