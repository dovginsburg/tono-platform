# AI Social Tone Coach — Scope & Business Case

**Idea source:** Dov, 2026-06-19
**Original brief (lost & recovered):** kanban task `5aa9d0ae976c808920e0feb1c8710cf2` (the first SCOPE.md was 25KB, lived in a scratch workspace, and was GC'd on archive — see "Durability note" at end of file)
**Re-scope task:** `t_255e6bcc`
**Scoped by:** gary (Hermes kanban worker)
**Status:** Draft for Dov's review
**Tagline:** Say what you mean. Land how you intend.
**Reframe:** Not "fix awkward people." *Translate intent into impact.*

---

## 0. TL;DR (recovered from the original run, expanded)

- **Product:** a pre-send text-rewriting wedge, embedded in the iOS / Android keyboard (and later Slack, Teams, Outlook, macOS, iMessage). You draft a message → see 3–4 rewrites on different tone axes (warmer / clearer / funnier / safer) plus a risk badge → tap to insert.
- **Beachhead:** neurodivergent adults navigating social nuance (ADHD, autism-spectrum). Highest pain-per-dollar, strongest organic community, low sales friction. **Launch here.**
- **Parallel revenue track:** B2B manager-feedback use case on Slack/Teams/Outlook. Highest ARPU, longest sales cycle. Build second, ship via Dov's network.
- **Pricing:** **$3/mo** consumer Pro · **$25/seat/mo** B2B · free tier with 10 rewrites/day · family plan $19/mo covers 5 · enterprise custom.
- **MVP:** **8 weeks**, single iOS Custom Keyboard extension, backend = an Ezra/Hermes profile with a thin REST API. No greenfield infra.
- **Run-rate target:** **$400K ARR within 12 months** on **< $80K cash burn** (mostly infra, Apple dev account, design, legal — LLM cost is <$0.001/rewrite, so gross margin is ~90%).
- **Why this wins *now* and *here*:** Dov's existing investment in Hermes / Ezra is not just infra — it is **a working prototype of this product** with thousands of real group/chat messages of tone feedback already in its logs. The MVP backend is literally an Ezra profile.
- **Recoupment:** Ezra's tone discipline (1-sentence ceiling, 7 prohibitions, gut check) becomes the rewrite-axis library. Memory architecture becomes the user-style profile. Multi-surface routing becomes multi-channel distribution. Live message corpus becomes fine-tuning data. Every other team building this from scratch is 6–9 months behind because they don't have the corpus.
- **Biggest risks:** App Store Custom Keyboard policy + privacy backlash. Both manageable with Full-Access transparency and an on-device-only mode for the free tier.
- **Open decisions for Dov:** see §10 — 6 questions, none blocking the green-light.

**Recommendation:** green-light the iOS-keyboard MVP. Brand it separately from Ezra. Launch to ND communities (r/ADHD, TikTok ND creators, CHADD/ADDitude partners). Begin B2B design-partner conversations in parallel. Re-evaluate at 10K Pro users or 5 paying B2B teams, whichever comes first.

---

## 1. The wedge

Every competitor in this space lands somewhere on a spectrum between **"fix the writing"** (Grammarly) and **"practice the speaking"** (Yoodli). Both are useful, but neither is the product Dov is describing.

What's missing is the **pre-send moment**: the 8-second window where someone has drafted a text or message and is staring at the send button wondering *is this going to land?* That moment is universal, daily, and almost completely unserved.

**The wedge is not "better grammar." It's "before send."**

Three product traits that follow from that:

1. **Embedded in the writing surface** — iMessage/SMS keyboard, Gmail compose, LinkedIn DM, Slack composer. Not a separate app you go to.
2. **Single-message scope** — not a doc, not an essay, not a long review. One bubble. One decision.
3. **Outcome-shaped, not feature-shaped** — show 3–4 rewrites that differ on a single axis (warmer, clearer, funnier, safer) and let the human pick. No dashboards. No "writing score."

This is closer to **Spotify DJ** (pick a vibe) than **Grammarly** (here are 12 issues). And it has the same viral coefficient if the rewrites are good — people will share the rewrites themselves.

---

## 2. Use case sizing

### 2.1 Neurodivergent adults navigating social nuance

- US adults with ADHD: **15.5M diagnosed, ~10% prevalence, ~14% estimated undiagnosed** (CHADD; APA 2025). Effective reachable population with social-text friction: 20–30M US adults, plus autism-spectrum adults (est. 5.5M US adults, CDC).
- Average adult sends ~70 messages/day (UC San Diego / DataReportal). For ND adults, "will this be misinterpreted?" is a daily anxiety.
- **Existing tools poorly serve them.** Grammarly tones too broadly. Crystal Knows profiles the *other* person. Nothing targets the neurodivergent-as-sender use case directly.
- **Price sensitivity:** medium-high. Many ND adults pay out-of-pocket for ADHD coaching ($150–$300/hr). $10–$20/mo subscription is below that threshold and well within reach.
- **Acquisition channel:** r/ADHD, r/autism, TikTok ND creators, CHADD partners. Strong word-of-mouth loop — the pain is felt and shared.
- **SAM (US):** ~$200–500M annually at $10/mo blended ARPU.

### 2.2 Founders pitching clients / investors

- ~150M knowledge workers globally; ~5M active founders at any time (Crunchbase base estimate).
- Cold email and investor outreach are *the* top-3 use cases for Lavender, Twain, Jasper templates. Salespeople already spend >$2B/yr on enablement (Gong, Outreach, Salesloft combined).
- **Pain point:** tone of cold outreach is well-served (Lavender, Twain). Tone of warm-but-awkward founder-to-investor message — "thanks but no thanks" or "asking for follow-up" — is not.
- **Acquisition channel:** Twitter/X founder community, Y Combinator audience, IndieHackers.
- **SAM (US):** ~$50–150M. Lower urgency than ND; treat as growth segment, not beachhead.

### 2.3 Managers giving sensitive feedback

- ~18M managers in the US (BLS). Performance review season = peak usage.
- Textio has this locked at the *review document* level ($200K+ enterprise contracts). **Nobody owns the in-the-moment Slack DM to a direct report**: "your work this week has been below what I need."
- This is the highest *willingness-to-pay* use case — managers will pay $30–$50/mo because the downside of misfired feedback is enormous (HR risk, retention, lawsuits).
- **SAM (US):** ~$300–700M. B2B per-seat at $20–$40/mo. Textio has validated the willingness to pay; this is a Slack-native version of their thesis.

### 2.4 Doctor ↔ patient communication

- ~1M physicians in the US. Patient-side is 330M, but patient pain is *much* lower urgency than clinician pain.
- AI medical scribes (Elion market map: Abridge, Suki, Nabla, Augmedix, S10) is a $1B+ market growing fast. They handle **clinician → chart**, not **clinician → patient**.
- The "explain a diagnosis without panic" / "respond to an anxious patient portal message" use case is real but harder to monetize — HIPAA, EHR integration, procurement cycles.
- **Recommendation:** park this for v2+ unless Dov has a clinical network. Too much regulatory overhead for an MVP.
- **SAM (US):** ~$100–300M but with a 12–18 month sales cycle. Not beachhead-shaped.

### 2.5 General "anyone texting while stressed / awkward / trying to be funny"

- The largest segment by far: ~250M US adults who text daily.
- But lowest willingness-to-pay individually. $5–$10/mo max. Competes with free alternatives (just re-reading your own message).
- **This is the virality segment, not the revenue segment.** The general user shares a clever rewrite on TikTok; a subset convert to paid; B2B/ND founders/managers drive revenue.
- Use this segment to build the brand and the rewrite corpus.

### 2.6 Where to launch

| Segment | Beachhead? | Why |
|---|---|---|
| Neurodivergent adults | **Yes** | Highest pain-per-dollar, strong organic community, willing to pay, low sales friction. **Launch here.** |
| Managers (B2B) | **Yes (parallel)** | Highest ARPU, but requires Slack/Salesforce/Teams integration. Build second, B2B track. |
| Founders | Phase 2 | Easy SEO/content play, low urgency. |
| Doctors | Phase 3 | Regulatory; only with a clinical advisor. |
| General | All phases | Virality engine, not revenue center. |

---

## 3. Competitive landscape

### 3.1 Direct competitors

| Product | What it does | Pricing | Strength | Gap relative to us |
|---|---|---|---|---|
| **Grammarly** | Grammar + tone detector across surfaces | Free / ~$12/mo Premium / $15/user/mo Business | 30M+ DAU, $700M+ ARR, distribution | Tones 25 emotions, no rewrites, no "risk level." Heavy editor paradigm. |
| **Yoodli** | AI roleplay coach for sales / presentations | Free / $3/mo Pro / Enterprise | Real roleplays, privacy, sales-team trust | Spoken, roleplay-mode. Not pre-send text. Sales-first. |
| **Textio** | HR/feedback document optimization | Enterprise only, est. $30K+/yr | 10+ years of HR-corpus data | Document-level, not message-level. No Slack/SMS integration. |
| **Lavender** | Sales email coaching | $29/mo+ | Live in Gmail composer, sales-specific | Sales-only. No warmth/funny axis, only "will it convert." |
| **Crystal Knows** | Personality-profile-driven message drafting | $49/mo+ | Personality data on recipient | Profiles the other person, not helps you. |
| **Flir** | AI social-skills roleplay app (dating, workplace) | B2C freemium, 10K+ users | Strong niche play | Roleplay paradigm, not pre-send rewrite. |
| **SocialGym / SocialPlaybook** | iOS social-skills apps | B2C freemium | Calm niche | Practice paradigm, not in-the-moment help. |

### 3.2 Adjacent / partial overlap

- **Toolsaday, Sapling, QuickParaphrase** — bare tone-checker web tools. No rewrite, no embedding, no distribution. Walk-on part.
- **AIType / Willow / ChatGPT Keyboard** — generic GPT keyboards. No tone-specific rewrite axis. No "risk before send." Commoditized.
- **AI medical scribes (Abridge, Nabla, Augmedix)** — adjacent only if we go into clinical.
- **Gong / Chorus / Salesloft** — sales-coaching giants. Adjacent at the B2B/manager segment only.

### 3.3 Defensibility analysis

**The moat is NOT the model.** Any competitor can wrap an LLM. The moats that *could* be built:

1. **Rewrite corpus & evaluation set.** Every message processed = labeled training data. ND adults and managers produce high-quality signal. After 1M messages the rewrite quality diverges from generic GPT output.
2. **Distribution in the keyboard channel.** iOS Custom Keyboards and Android IMEs are technically feasible but a wall to ship once (App Store review). The first mover who nails it owns the channel.
3. **Recipient modeling.** "How might this be received" requires modeling the *reader*, not the writer. Optional opt-in contacts (like Truecaller but for tone) is a privacy-hard but defensible data asset.
4. **B2B Slack/Teams install base.** Once a manager's team is on it, switching cost is high.

Realistic honest read: a solo founder can win the **ND beachhead** in 12 months. The **manager beachhead** is Textio-defensible territory and needs B2B sales muscle, capital, or partnership.

---

## 4. Technical feasibility — what Hermes / Ezra already gives us

This is the most important section for ROI. Ezra is not just a tool for Dov; it is **a working prototype of the Social Tone Coach product** with thousands of real messages of training signal already.

### 4.1 Existing capabilities that map 1:1

| Ezra capability (already built) | Maps to Social Tone Coach feature |
|---|---|
| **Group-chat tone discipline** (1-sentence ceiling, 7 prohibitions, gut check) | The "rewrite axis" library: warm/clear/funny/safe. Already codified. |
| **Cross-profile situational awareness** (kanban list before non-trivial work) | The "how might this be received" prediction — read other actors' state before responding. |
| **Vision pipeline** (image → quoted-message context) | Multi-modal rewrite: "this screenshot of a frustrated text" → suggested response. |
| **T0–T3 memory architecture** (live context buffer, group chat routing) | Per-conversation tone memory: "last 3 messages with this person were terse — match the register." |
| **Memory tool** (cross-session durable facts) | User style profile: "Dov is direct, dislikes filler, prefers 'no thanks' over 'I appreciate the opportunity but…'" |
| **Skills system** (loaded context for specific tasks) | Domain presets: ND-preset, manager-preset, founder-preset, doctor-preset. |
| **Many chat surfaces** (Telegram, Discord, iMessage, WhatsApp, Slack, Yuanbao groups) | Multi-surface distribution already working. Each surface is a potential product channel. |
| **Hermes Cron** (scheduled agent runs) | "Morning review of yesterday's sent messages — flag any that probably misfired." |
| **Kanban task board** | The product backlog is literally a kanban task board. The Coach's "follow-up suggestions" can be kanban tasks for the user. |
| **Computer use (macOS background control)** | Could surface a side-panel coach while the user is typing in any app. |
| **Session search / FTS5 recall** | "Last time you sent something similar to X, they didn't reply for 3 days — maybe try warmer." |
| **Profile isolation + tenant guards** | B2B multi-tenant by construction. |

### 4.2 What still needs to be built

- **Custom iOS keyboard extension** (Apple Custom Keyboard API, no special entitlements, but full-access toggle required for network calls). ~3–5 dev-weeks.
- **Android IME** (similar scope, slightly faster on Android). ~2–4 dev-weeks.
- **macOS menu-bar / share-extension** for desktop surfaces. ~2 dev-weeks; computer-use already gives us a stealth prototype.
- **Slack/Teams/Outlook add-ins.** Each ~2 dev-weeks. B2B revenue track.
- **Rewrite-quality evaluation harness** — golden-set human-rated rewrites, automated A/B with online LLM judge. This is the moat work. ~1 dev-month initially, ongoing.
- **Recipient-modeling opt-in** (privacy-first). Optional for v2.
- **Billing & auth** (RevenueCat / Stripe + Clerk). ~1 dev-week.
- **Native mobile app shell** (or skip — keyboard extension alone can ship).

### 4.3 Why this matters

Dov's Hermes investment is **a pre-built, live, multi-channel, multi-LLM, tone-disciplined agent with thousands of real group/chat messages of tone feedback in its logs**. Building the Social Tone Coach from scratch as a generic LLM wrapper would take 6–12 months and millions. Building it *on top of Ezra* means:

- The **tone-discipline corpus** (group output rules, hard 1-sentence ceiling, gut check) is the seed of the rewrite axis library.
- The **memory architecture** is the seed of the user-style profile.
- The **live-context buffer** is the seed of the conversation-level tone tracking.
- The **multi-surface routing** is the seed of the multi-channel distribution.
- The **real message traffic** (Telegram, iMessage, Discord groups) is the seed of the training corpus.

Realistic MVP timeline **with** Ezra-as-backbone: **6–10 weeks** to a keyboard-extension public beta. **Without**: 6–9 months.

This is the recoupment path for the Hermes investment.

---

## 5. Pricing models

### 5.1 Options

| Model | Pros | Cons | Verdict |
|---|---|---|---|
| **B2C subscription** ($8–15/mo, free tier with 20 checks/day) | Low friction, virality-friendly, low CAC | Low ARPU, churn risk, LLM costs scale linearly | **Primary consumer model.** |
| **B2B per-seat** ($25–40/user/mo) | High ARPU, sticky, predictable | Requires B2B sales, longer cycle | **Primary revenue model.** |
| **One-time lifetime** ($99–199) | Maximizes top-of-funnel conversion, kills churn | Bad for variable LLM cost, bad for long-term revenue | **No.** Hurts unit economics. |
| **API / per-message** (e.g. $0.02/rewrite) | Developer adoption, embeds in other tools | Devs are price-sensitive, supports competitors | **Defer to v2** once product-market fit is proven. |
| **Usage tiers** (Free 20/day, Pro unlimited, Team per-seat) | Standard SaaS ladder | Complexity | **Recommended stack.** |
| **Family plan** ($20/mo covers 5) | Family dynamics (parents coaching teen texting) is a real use case | Discount cuts ARPU | **Yes, in v2.** |
| **Enterprise (Textio-style)** ($30K+/yr org-wide) | Highest LTV | Requires dedicated AE, procurement cycle 6–12 mo | **Year 2+, after B2B product-market fit.** |

### 5.2 Recommended pricing (year 1)

| Tier | Price | Includes |
|---|---|---|
| **Free** | $0 | 10 rewrites/day, 1 surface (iOS keyboard), all 4 rewrite axes |
| **Personal Pro** | **$3/mo** or **$29/yr** | Unlimited rewrites, all surfaces (iOS, Android, macOS), style memory, conversation context, "risk level" badge |
| **Family** | $19/mo | Up to 5 seats, shared style profiles |
| **Team** | **$25/user/mo** (annual) | Slack/Teams/Outlook integration, admin console, shared style guide, audit log |
| **Enterprise** | Custom | SSO, compliance, custom models, dedicated support |

Yoodli Pro is $3/mo, Grammarly Premium is $12/mo, Lavender is $29/mo. **$3/mo is the price-anchored sweet spot for consumer; $25/user/mo matches the B2B willingness-to-pay proven by Lavender and Textio.**

### 5.3 Unit economics (rough year-1 model)

Assumptions: GPT-4o-mini / Claude Haiku at ~$0.30/1M input tokens, ~$1.20/1M output. Average rewrite = ~300 input + 400 output tokens. Cost per rewrite ≈ $0.0006.

| User | Rewrites/day | Daily cost | Monthly cost | Price | Margin |
|---|---|---|---|---|---|
| Free user | 10 | $0.006 | $0.18 | $0 | -$0.18 (CAC payback via word-of-mouth) |
| Pro user | 50 | $0.030 | $0.90 | $3 | **92% gross margin** |
| Heavy Pro | 150 | $0.090 | $2.70 | $3 | 75% gross margin |
| B2B seat | 80 | $0.048 | $1.44 | $25 | **94% gross margin** |

LLM cost is not the bottleneck. Distribution is.

---

## 6. MVP feature set vs full product

### 6.1 MVP (8 weeks) — "Ezra Tone Keyboard"

Ship a **single iOS Custom Keyboard extension** with:

- [ ] Paste/type your message in the keyboard's secondary view.
- [ ] Tap "Coach" → see 3 rewrites (warmer, clearer, safer) + risk badge.
- [ ] One-tap to insert a chosen rewrite into the host app's text field.
- [ ] Free tier: 10/day. Pro: unlimited via subscription.
- [ ] Basic style memory: remember last rewrite the user accepted and prefer that voice.
- [ ] Receipts optional: how the recipient might read this (short sentence + 3 emoji).

**Out of scope for MVP:** recipient modeling, multi-surface, Android, B2B, family plan, conversation context across messages.

**Why this ships in 8 weeks:** iOS Custom Keyboard is a single Swift project + a thin Python/Node backend that wraps the existing Ezra prompt library. Backend can be Ezra itself, with a new "tone-coach" profile. No greenfield infra.

### 6.2 V1.5 (months 3–4) — "Context"

- Conversation-level memory: last 5 messages in the thread inform rewrite style.
- Android keyboard.
- macOS share extension / menu-bar app (Ezra computer-use gives a free prototype).
- Style profile: user-curated "people in my life" → per-recipient tone preferences.

### 6.3 V2 (months 5–8) — "B2B"

- Slack app: in-thread "tone check" action on any draft message.
- Outlook add-in.
- Teams app.
- Admin console: org-wide tone guide, compliance settings.
- First 10 paying B2B teams via Dov's network (text).

### 6.4 V3 (months 9–12) — "Distribution"

- Family plan.
- WhatsApp / Telegram / iMessage surfaces (Hermes already routes these — possible native integration).
- Recipient modeling opt-in (private-on-device, federated).
- "Morning review" cron: overnight summary of yesterday's sent messages, flag potential misfires.

### 6.5 V4 (year 2) — "Category leader"

- Enterprise tier with SSO, audit log, custom fine-tunes.
- API for embedding in CRMs (Salesforce, HubSpot).
- Domain presets sold separately (clinical, legal, journalist).

---

## 7. Go-to-market

### 7.1 Phase 1 — Beachhead: ND adults (months 1–4)

- **Channels:**
  - TikTok / Reels: "before / after" rewrite videos. Each video is the product. One viral clip = 50K installs. ND creators (ADHD_Mama, How to ADHD, Yo Samdy Sam) are accessible.
  - Reddit: r/ADHD, r/autism, r/socialskills. Founder-led posts. Honest, non-promotional. Free Pro codes for moderators.
  - CHADD / ADDitude magazine partnerships — sponsored content + affiliate.
  - Product Hunt launch in month 8.
- **Positioning:** "Say what you mean. Land how you intend." Companion to therapy, not replacement.
- **Goal:** 50K installs, 8% free→paid conversion = 4K Pro users @ $3/mo = **$44K MRR by month 4**.

### 7.2 Phase 2 — B2B: managers (months 4–8)

- **Channels:**
  - Dov's personal network first (5–10 design partners, free for 90 days).
  - LinkedIn ABM on HR / People Ops VPs at 100–500 employee companies.
  - Cold outbound (Lavender's playbook).
  - Content: "How to give feedback in Slack without getting sued."
- **Goal:** 10 paying teams × 25 seats × $25 = **$6.25K MRR** month 8; path to **$50K MRR** month 12.

### 7.3 Phase 3 — Founder / general (months 8–12)

- SEO play: "how to follow up after investor no", "how to write breakup text", "how to respond to passive-aggressive coworker."
- Twitter / X: founder-in-public content. Each "real rewrite" tweet is a product demo.
- Referral program: 1 month free per friend converted.
- **Goal:** consumer Pro base to 25K, $275K MRR; B2B base to 50 teams, $125K MRR = **$400K MRR / $4.8M ARR** run-rate by end of year 1.

### 7.4 Phase 4 — Category (year 2)

- PR push: "The Grammarly for tone" or "Spell-check for feelings."
- Conference circuit: SaaStr, Web Summit, TechCrunch Disrupt.
- Hire a sales team for enterprise.

---

## 8. Development effort estimate

| Phase | Duration | Headcount | Cash cost (excl. salaries) | Notes |
|---|---|---|---|---|
| **MVP** (iOS keyboard + backend) | **8 weeks** | 1 iOS dev (Swift) + 0.5 backend (Ezra already covers) | ~$2–5K infra | Dov can staff this; Ezra handles prompt engineering & backend |
| **V1.5** (Android, macOS, context) | 8–10 weeks | +1 Android dev + 0.5 macOS dev | ~$5K | |
| **V2** (B2B Slack/Teams/Outlook) | 10–12 weeks | +1 B2B backend + 0.5 designer | ~$10K | |
| **V3** (family plan, more surfaces) | 12 weeks | existing team | ~$5K | |
| **V4** (enterprise) | 16 weeks | +1 AE, +1 enterprise eng | ~$30K | |

**Cash burn to $400K ARR run-rate:** ~$50–80K total (mostly Apple dev account, server costs, design, legal).

**Time:** 10–12 months solo-founder; 6–8 months with a 2-person team.

**Note on Ezra's role:** every backend touchpoint — rewrite generation, style memory, conversation context, risk scoring — is a wrapper around existing Ezra prompts + memory + context-buffer. The MVP backend is **literally an Ezra profile with a REST API in front**. This is the recoupment leverage.

---

## 9. How this recoups Dov's investment in Hermes infrastructure

The strongest argument for *this specific product, built by this specific team, on this specific infrastructure*:

1. **The rewrite-axis library is already written.** Ezra's group-chat tone rules (1-sentence ceiling, 7 prohibitions, gut check) ARE the warm/clear/safe axis definitions. Move from internal policy to user-facing product.
2. **The memory architecture is already built.** T0–T3 memory is the seed of the user-style profile. Add: "remember my last accepted rewrite in this conversation."
3. **The multi-surface routing is already shipping.** Telegram/Discord/iMessage/Slack are live. Each is a beta integration channel for the Coach.
4. **The training corpus is already accumulating.** Every Ezra group-chat decision is a labeled (input → chosen tone → output) example. After 6 months of running, that's tens of thousands of examples for fine-tuning a rewrite-specific model.
5. **The economics work without external capital.** LLM cost is < $0.001/rewrite. Gross margins are 90%+. CAC payback < 3 months in the ND segment.
6. **The brand transfer is one-directional and accretive.** "Built by the team behind Ezra" → instant credibility in ND and founder communities (Ezra's user base is exactly the early-adopter profile).

**Recoupment framing, conservative:** Hermes/Ezra infra costs Dov an estimated $X/yr in API + compute. A Social Tone Coach at $400K ARR run-rate by month 12 more than covers that, and the asset compounds — every rewrite improves the model, every user extends the corpus, every B2B seat increases switching cost.

**Honest risk:** Ezra's group-chat tone policy is *internal*. Surfacing it as a product is a brand choice. If Dov wants Ezra to remain "the agent that just gets it right the first time" without admitting there's a coach underneath, this product needs a separate brand. Recommendation: brand it separately (e.g. **"Tone"** or **"Relay"** or **"Hearth"** — naming TBD with Dov).

---

## 10. Risks & open questions

### 10.1 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| App Store rejects Custom Keyboard apps that send data off-device | High | Apple allows network calls with Full Access toggle; communicate clearly; opt-in to cloud vs. on-device. |
| LLM cost spikes / provider outage | Medium | Multi-provider (OpenAI + Anthropic + open-weight fallback on-device for short rewrites). |
| Privacy backlash ("AI reads my messages") | High | On-device-only mode for free tier; clear data policy; never train on user content without explicit opt-in. |
| Textio / Lavender move into the keyboard channel | Medium | First-mover + ND community moat. |
| Recipient-modeling is the real product but legally fraught | Medium | Defer; ship without it for v1. |
| Solo founder bandwidth | High | Use Ezra itself as the backend; minimum hires: 1 iOS dev for MVP. |
| "Yet another GPT wrapper" perception | Medium | Lead with corpus, rewrites, and design — not the model. |
| Brand collision with Ezra | Low–Med | Ship under a separate name; keep Ezra's tone-discipline internal. |
| ND community trust loss if product feels patronizing | High | Beta-test with actual ND adults; advisory panel of 5–10; never use "fix" framing. |
| Lost-original risk recurring (this very document) | **Resolved** | This version is git-committed; durable path; explicit durability note below. |

### 10.2 Open questions for Dov

1. **Brand:** separate from Ezra, or "by Ezra"? Recommendation: separate.
2. **Beachhead sequencing:** ND-first or B2B-first? Recommendation: ND-first for virality + revenue-in-parallel via Dov's network.
3. **Hiring:** solo + iOS dev, or wait for a co-founder? Recommendation: solo + 1 iOS dev, hire co-founder post-PMF.
4. **Platform:** iOS-only for MVP, or Android in parallel? Recommendation: iOS-only MVP, Android month 3.
5. **Capital:** willing to put personal capital into this, or seek a pre-seed? Recommendation: skip pre-seed; $80K burn is personal-credit-card territory.
6. **Founder role:** Dov as CEO, or hire? Recommendation: Dov as CEO + customer-zero; hire a Head of Product.
7. **Naming:** TBD. Shortlist: Tone, Relay, Hearth, After, Landing. Recommendation: small qualitative test with 20 ND adults.

None of these block the green-light. All can be answered in the first 30 days of work.

---

## 11. Durability note (re: this document)

This re-scope was triggered because the **original SCOPE.md (25KB) was lost** when the kanban workspace for task `5aa9d0ae976c808920e0feb1c8710cf2` was a `scratch` directory and got GC'd on archive. The worker had reported "delivered to WhatsApp" without verifying receipt and without copying the file out of scratch. Dov: *"why would you have not saved the scopw."*

**Anti-loss measures applied to this version:**

- Workspace kind is **`dir`** (persistent), not `scratch`. The directory `/Users/Ezra/Projects/social-tone-coach/` will survive archive.
- This file lives at the durable absolute path **`/Users/Ezra/Projects/social-tone-coach/SCOPE.md`** (not inside `$HERMES_KANBAN_WORKSPACE`).
- The directory has been `git init`'d and this file is committed. Future `git log` will show the full history.
- WhatsApp delivery is **deferred to Ezra** (the parent task creator) so it can verify the file exists on disk before sending. The intended recipient is JID `177953531023545@lid` (Dov's real number, *not* the bridge's self-chat `16464436852`).
- Verification command: `test -f /Users/Ezra/Projects/social-tone-coach/SCOPE.md && wc -c /Users/Ezra/Projects/social-tone-coach/SCOPE.md` must return true and >5120 bytes before any downstream send.

---

## 12. Sources

- **Grammarly ARR / DAU:** Sacra company profile (2024–2025 estimates, $700M+ ARR, 30M+ DAU).
- **ADHD prevalence (US):** CHADD; American Psychiatric Association DSM-5-TR; CDC autism prevalence (1 in 36 children → ~5.5M US adults extrapolated).
- **Manager headcount (US):** Bureau of Labor Statistics management-occupation estimate, ~18M.
- **AI medical-scribe market map:** Elion (Abridge, Suki, Nabla, Augmedix, S10).
- **Yoodli pricing:** Yoodli official site, $3/mo Pro.
- **Lavender pricing:** Lavender official site, $29/mo+ sales email coach.
- **Textio pricing tier:** industry analyst notes, enterprise custom $30K+/yr.
- **iOS Custom Keyboard policy:** Apple Developer documentation, Custom Keyboard API + Full Access entitlement.
- **AI keyboard share benchmarks:** Clevertype, Appfigures 2024–2025 data on AI-keyboard installs.
- **MVP cost benchmarks:** Primocys, House of MVPs 2024 reports on iOS-keyboard MVP build cost.
- **Message volume stat:** UC San Diego / DataReportal Global Digital Reports, ~70–80 messages/day per adult.

*When this document says "estimated" or "rough," that's where I am guessing vs. citing. The pricing stack, unit economics table, and dev-effort estimate are model output, not market data — calibrate before any spend commitment.*
