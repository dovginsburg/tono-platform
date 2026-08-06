# Tono — Final-Release Seal / Verification Handoff (Opus 4.8, medium)

**Lane:** sole Tono mutable writer, no subagents, no background tasks. Every
command below ran **synchronously in the foreground** and was awaited to its
exit. **Date:** 2026-08-06. **Worktree:**
`/Users/Ezra/.hermes/claude-worktrees/tono-final-release-opus48-20260804`.
**Runtime:** claude-opus-4-8, medium/default effort.

This handoff separates **verified local evidence** from **operator-owned gates**
and invents nothing. Source is **SOURCE SEALED**, not released/live/store-ready.

---

## 1. Identity

| Ref | SHA |
|---|---|
| **Sealed branch tip (this lane)** | `17427ee4a5b02f6d8181762f72cdf3e06da2a20f` |
| tip tree | `12993056352329fb775e56502c5b30d9f812d830` |
| parent (unchanged, prior lane) | `02a8ee36d2172e62375022ff11d7b94ac3b09295` (Stripe dedicated-account isolation) |
| grandparent | `73e9337` (Android versionCode 120→121 blank-letters fix) |
| Branch | `claude/tono-controllable-completion-opus48-20260804` |
| Origin tip | `425e356` — **HEAD is 3 commits ahead, all UNPUSHED** (`73e9337`, `02a8ee3`, `17427ee`) |

**Working tree:** clean except `.gitignore` (`+.gstack/`) — a pre-existing,
benign tooling-ignore line present at lane start; **preserved, deliberately
left uncommitted** (orthogonal to the auth fix). No reset/stash/clean was ever run.

---

## 2. What this lane changed

**One commit, one file, +9 −2** — `17427ee`, `apps/web/src/app/login/page.tsx`.
Both edits fix defects the web contract suite flagged as **red before this lane**
(they predate the session — present at origin tip `425e356` too):

1. **Anti-enumeration collapse restored.** `requestMail` rendered the raw
   `unknown_failure` outcome, distinct from `check_your_email`. The
   magic-link/reset/resend backend answers **200 + `check_your_email` for a
   known AND an unknown address** (verified in `apps/backend` +
   `apps/web/src/lib/email-auth.ts::classifyBackendStatus`), so surfacing
   `unknown_failure` on its own re-created an account-enumeration oracle in the
   UI. Collapsed to the same confirmation; only outsider-observable failures
   (throttling, outage) stay distinct. Restores the exact property the code's
   own comment at login:281 already claimed.
2. **Sibling token removed from the shipped login bundle.** The magic-link
   explainer comment embedded the sibling product's name, tripping the
   contamination guard that forbids any sibling identifier in the rendered auth
   files. Reworded to name the shared-tenant sender without the token.

No API surface, contract, native (iOS/Android), or backend code changed.

---

## 3. Verification evidence (all foreground, exact counts)

| Gate | Command | Result |
|---|---|---|
| **Stripe isolation (hostile)** | `pytest tests/test_stripe_dedicated_account_isolation.py` | **9 passed** |
| **Magic-link (hostile)** | `pytest tests/test_email_magic_link.py` | **8 passed** |
| **Full backend suite** | `pytest -q` (apps/backend) | **1197 passed, 2 skipped, 0 failed** (107.9s) |
| Backend contract subset | `pytest -k "openapi or drift or contract"` | 147 passed |
| **Web unit/contract tests** | `npm test` (apps/web) | **195 passed, 0 failed** (was 193/2 pre-fix) |
| **Web typecheck** | `npx tsc --noEmit` | exit 0, clean |
| **Web production build** | `npm run build` | exit 0 — "Compiled successfully", full route table |
| **openapi drift** | `python3 scripts/ci/export_openapi.py` then `git diff` | **byte-identical, IN SYNC** |
| **Contamination sweep** | grep sibling tokens across shipped `apps/`+`packages/` | **clean** — all hits are isolation-documentation or negative test assertions |

**Web lint:** `npm run lint` exits 1 **only** because `next lint` is deprecated
in this Next version and drops into an interactive ESLint-setup prompt (no
ESLint config wired). This is an environment/tooling limitation, **not a code
defect**; `tsc --noEmit` (the stronger static gate) is clean.

**Native (iOS/Android):** **untouched this lane** — `git status` shows zero
native-file changes. Android toolchain OOMs on this machine (AAPT2 daemon,
documented) and a full iOS archive tests the machine, not this web-only change,
so native was not re-burned. Prior sealed native evidence carries (Build 126
lane: iOS signed 938/0, Android 112 green). Native re-verification remains
environment-bounded and operator/CI-owned.

---

## 4. Owner Stripe correction (2026-08-06) — addressed

Owner reports **three separate Stripe accounts** (Tono / TandemPaws /
TandemSkills), same Chase payout bank linked to each. Reported provider state,
**not** proof of activation.

**Product-scoped isolation — verified in code (`apps/backend/payments.py`,
committed `02a8ee3`, unchanged this lane):**
- `TONO_STRIPE_ACCOUNT_ID` (non-secret `acct_…`) declares the only account Tono
  may bill. `_require_tono_stripe_account()` reads back `stripe.Account.retrieve()`
  behind the configured key and **fails closed (503)** on any mismatch; a
  mismatch never names the foreign account back to the caller.
- `GET /v1/stripe/readiness` reports **non-secret booleans + public ids only**;
  it echoes the live `account_id` **only when it matches** the declared expected
  account. No key, price id, or webhook secret is ever returned.

**Independent sanitized readback in THIS environment** (in-process
`stripe_readiness()`; presence-only env probe, no values printed):
```
secret_key_configured=false  webhook_secret_configured=false
price_monthly_configured=false  price_yearly_configured=false
expected_account_id=null  account_identity_verified=false  account_id=null
catalog_version=1.0.0  ready=false
```
- **No Tono Stripe credentials are present locally** — so `livemode`,
  `details_submitted`, `charges_enabled`, `payouts_enabled`, and the runtime
  account match are **unreadable from here by design** and remain operator gates
  against the deployed (Render) environment.
- **No sibling Stripe credentials are present either** (both sibling env vars
  probed `present=false`), so there was **zero risk** of any read touching a
  foreign account. Tono code references no sibling-scoped variable.
- Rail separation intact and test-encoded: Stripe = web Checkout/Portal; iOS =
  StoreKit IAP; Android = Play Billing; RevenueCat reconciles each rail onto the
  canonical account (cross-platform double-charge guard, `cac1008`).

### 4a. Contaminated local credential — BLOCKER (receipt 2026-08-06)

`/private/tmp/stripe-contaminated-local-credential-blocker-20260806.txt`: Ezra's
read-only probe found the local Keychain label **`tandempaws-stripe-live`
resolves to account `acct_1TRJaBQ93BpfjtrE`** ("Dov Ginsburg MD PLLC"), whose
live catalog mixes **TandemPaws + ParentScript + Tono** products. It is a
**mislabeled/legacy contaminated account — NOT a dedicated Tono (or TandemPaws)
account** and must never be bound, used, deployed, mutated, or cleaned.

- **This lane never touched that credential.** Only env-var *presence* was
  probed (all `false`) and the in-process readiness ran with no network. No
  Keychain read, no binding.
- **Corroboration — the code already refuses it.** `acct_1TRJaBQ93BpfjtrE`
  appears in the entire tree **exactly once**, as the forbidden `LEGACY_ACCOUNT`
  fixture in `test_stripe_dedicated_account_isolation.py`; the checkout guard is
  tested to refuse it (503, without disclosing it) **before** any Stripe object
  is created. It is never an allowed/expected/env-bound value anywhere.
- **Live-secret sweep clean:** no `sk_live`/`rk_live`/`pk_live`/`whsec`/real
  `acct_1…` material embedded in shipped source — only the forbidden fixture and
  synthetic leak-detection probes (`ZQXsk_live_…`, asserting `/health` never
  leaks).
- **EXACT GATE:** the new product-dedicated Stripe accounts may exist in the
  Dashboard, but **product-specific reusable live runtime keys / account IDs are
  NOT yet present in this execution lane.** Each product (Tono included) stays
  **fail-closed** until its OWN dedicated account identity + credential are
  securely installed and read back. No Stripe readiness/binding claim may be
  made on the strength of the `tandempaws-stripe-live` credential or a linked
  bank.

---

## 5. Existing-user-only branded magic-link (gate 1) — preserved & verified

`test_email_magic_link.py` 8/8 + web 195/195. Contract (openapi.json,
`/v1/auth/email/magic-link`, in sync): Tono-branded link, **existing-users-only
against Tono's own ledger** (`has_verified_email_account`) — unknown address
sends/creates nothing; anti-enumerating (identical accepted response for
known/unknown; per-address rate gate applied before ledger read so timing can't
answer either). This lane hardened the **web** end of that same property (§2.1).

---

## 6. Rollback

- Revert this lane entirely: `git revert 17427ee` (or `git reset --hard 02a8ee3`),
  which returns to the prior sealed parent. The single changed file is
  `apps/web/src/app/login/page.tsx`; reverting re-introduces the two web
  contract-test failures but no functional/native/backend change.
- `.gitignore` dirty line is inert; `git checkout -- .gitignore` drops it.

---

## 7. Remaining release spine (operator / provider / device — NONE done here)

All require owner-only irreversible action; **do not** infer any as complete:
1. **Push** the 3 unpushed commits (`73e9337`, `02a8ee3`, `17427ee`) after
   independent review (Ezra owns release mutations).
2. **Stripe live activation (Tono account only):** set `TONO_STRIPE_ACCOUNT_ID`,
   live secret, webhook signing secret, and both canonical price ids on Render;
   then confirm `GET /v1/stripe/readiness` → `ready:true` +
   `account_identity_verified:true`, and that `details_submitted` /
   `charges_enabled` / `payouts_enabled` / `livemode` are true on Tono's
   dashboard. Linked bank ≠ any of these.
3. **Store rails:** iOS 1.1/build 117 stays in Apple review (owner's call, do
   not swap to 126); Android production track still empty; RevenueCat store keys
   + real-device sandbox purchase proof.
4. **Native re-verification** on CI/capable hardware (iOS archive, Android
   build/lint) — not runnable here.
5. OAuth/passkey interactive human sign-in journeys (server halves fail-closed,
   already proven).

**Status: SOURCE SEALED at `17427ee`.** Every safely executable local
verification gate is green; every remaining gate is external/human/device.
