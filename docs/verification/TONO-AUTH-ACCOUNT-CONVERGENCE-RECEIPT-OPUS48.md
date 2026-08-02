# Tono — Auth / Account / Payment / History Convergence Receipt (Opus 4.8)

**Baseline:** `2358de9cacc48fbb4bff1cbe996f0bfb344e32e0` (tree `4753c97abb733cd79f6a3ad58a6c4302cbb68007`, parent `46db692943cd72fc62711ab3671c918a253eeed7`).
**Worktree:** `tono-auth-live-repair-opus48-20260802`. **Product:** Tono only.
**Author constraint:** sole writer, no subagents. **Date:** 2026-08-02.

This receipt separates five claim levels and never conflates them. Everything
in this change is **SOURCE_IMPLEMENTED**. Nothing here touches provider
configuration, deploys, uploads, build numbers, or legal terms, so
`PROVIDER_CONFIGURED`, `LIVE_AUTH_VERIFIED`, `PAYMENT_VERIFIED`, and
`SIGNED_DEVICE_VERIFIED` remain **NO** and are the operator's to earn.

---

## What was actually wrong (authoritative live evidence)

1. **Web "Continue with Apple" redirected into a sibling product's consent.**
   The button was gated only on `OAUTH_CONFIGURED = Boolean(SUPABASE_URL &&
   SUPABASE_ANON_KEY)`. Supabase drives the Apple redirect with the Services ID
   configured on its *dashboard* Apple provider — on the shared project that
   binding is a sibling product's, so Apple displayed "Use your Apple Account to
   sign in to <that other product>." The browser cannot read that binding, so
   the old gate could never have caught it.

2. **Google on web did not recognize the account already used on iOS.**
   iOS presents a *native* Google identity → canonical key `google:<google-sub>`.
   The website authenticates through Supabase → the identity arrives as
   `supabase:<supabase-uid>`, a different subject. `_resolve_provider_signin`
   steps 1–2 cannot see across that, so the same human split into two canonical
   accounts with divided history and entitlements.

Password reveal, forgot/reset/resend, passkeys, Stripe lifecycle, and payment
history already existed in source on all three surfaces (see the audit table);
they were not the gap. The "no show/hide control" observation was against the
**live Build 125** deployment, not this source tree.

---

## Change 1 — Web Apple button: fail-closed product-branding gate

**Files:** `apps/web/src/lib/apple-oauth-binding.ts` (new),
`apps/web/src/app/login/page.tsx`.

- New pure, unit-tested `appleWebSignInEnabled(servicesId, expected?)`. The Apple
  button renders **only** when an operator attests, via
  `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID`, that the Supabase Apple provider is bound
  to Tono's **own** Apple Services ID. The check is an **allowlist by Tono
  reverse-DNS shape** (or strict equality against an operator-pinned
  `NEXT_PUBLIC_APPLE_WEB_EXPECTED_SERVICES_ID`) — never a denylist of the
  sibling id, because embedding that literal would itself put a foreign client
  id into the compiled artifact.
- **Default (today's live state): the Apple button is hidden** and replaced with
  truthful recovery copy pointing at Google/email. No user is sent into another
  product's consent screen. Google and passkeys are unaffected.
- The gate is an operator seam, as the contract requires: the browser cannot
  verify the dashboard binding, so the correct posture is fail-closed until the
  operator both corrects the Supabase Apple provider **and** sets the env var.

### Build-verified proof (four scenarios, `next build`)

| Scenario (env) | Google btn | Apple btn | Fallback copy | `parentscript` in `.next` |
|---|---|---|---|---|
| Supabase unset | absent | absent | absent | 0 |
| **Supabase set, Apple id unset (live prod state)** | **1** | **0** | **1** | **0** |
| Supabase set, `APPLE_WEB_SERVICES_ID=com.tono.web` | 1 | 1 | 0 | 0 |

Reproduce (from `apps/web`, after `npm install`):
```
TONO_DEPLOYMENT_ENV=production \
TONO_SUPABASE_STAGING_PROJECT_REF=stagingref0123456789 \
TONO_SUPABASE_PRODUCTION_PROJECT_REF=abcdefghij0123456789 \
NEXT_PUBLIC_SUPABASE_URL="https://abcdefghij0123456789.supabase.co" \
NEXT_PUBLIC_SUPABASE_ANON_KEY="anon" \
npm run build
grep -c "continue with apple" .next/server/app/login.html   # -> 0 (fail closed)
grep -c "being finished"       .next/server/app/login.html   # -> 1 (truthful copy)
grep -rli parentscript .next | wc -l                         # -> 0 (uncontaminated)
```

---

## Change 2 — Account continuity: verified-email convergence (bidirectional)

**Files:** `apps/backend/store.py`, `apps/backend/server.py`,
`apps/backend/social_auth.py`.

- New `Store.find_verified_email_account(provider, sub, email)` — returns the ONE
  canonical account this identity should join by a **verified** email, or `None`
  when unsafe. It **attaches, it never merges**: it targets only an account whose
  address is verified and whose `{provider}_sub` column is empty (so a subject is
  never overwritten and two populated identities are never fused), and it refuses
  an **ambiguous** address (more than one candidate) so no account's history is
  silently orphaned.
- `_resolve_provider_signin` gains step 3 (between the pending-registration claim
  and the anonymous-device upgrade): converge onto that account when — and only
  when — the provider **proved** the address on this sign-in (`email_verified`).
- `social_auth` now captures the provider `email_verified` claim (Apple's string
  `"true"`, Google's bool) into `IdentityClaims`, and all three routes
  (`/v1/auth/apple`, `/v1/auth/google`, `/v1/auth/web`) thread it through. This
  also tightens Google email trust generally (an unverified Google email can no
  longer drive a merge).

Result: iOS Google → web Google (and the reverse) land on **one** canonical
account, preserving history and entitlements. An **unverified** email never
merges; an **ambiguous** one is left to explicit authenticated linking. The
existing explicit `link=True` provider-linking path and its 409-on-collision
semantics are unchanged.

---

## Change 3 — Verification authority hardening (defense-in-depth, pre-deploy)

**Files:** `apps/backend/supabase_auth.py`, `apps/backend/server.py`.

Found by independent release review before backend deployment. Two trust holes
that let the Change-2 convergence be driven by non-authoritative input:

1. **`_extract_claims` trusted `user_metadata.email_verified`.** GoTrue's
   `raw_user_meta_data` is **user-writable** (`auth.updateUser({ data })`), so a
   signed-in user could forge `email_verified: true` and — via verified-email
   convergence — attach their identity to a stranger's canonical account by
   claiming that stranger's address. Now verification is derived **only** from
   GoTrue-controlled evidence: the **top-level** `email_verified` claim (minted
   from `users.email_confirmed_at`) and **`app_metadata`** (service-role only).
   `user_metadata` is no longer consulted; absent authoritative evidence we
   default UNVERIFIED (fail closed). A forged flag cannot even override an
   authoritative `false`.

2. **Email/password login did not thread verified status into the resolver.**
   `auth_email_login` proves the address twice (provider withholds a session for
   an unconfirmed address; the re-verified token's GoTrue `email_verified` claim
   must be true, else 403) but then called `_resolve_provider_signin` **without**
   `email_verified`, so a confirmed password login stayed split from the person's
   existing identity. It now passes the authoritative `claims.email_verified`
   (True by construction at that point), so a verified password sign-in converges
   exactly like Apple/Google/web.

Public production settings independently verified compatible: `mailer_autoconfirm
=false`, email/apple/google enabled — so the top-level claim reflects real
confirmation and no legitimate flow is blocked.

### Adversarial tests (all new, in `test_account_continuity.py`)

- `test_extract_claims_ignores_user_writable_metadata` — forged `user_metadata`
  → UNVERIFIED; top-level and `app_metadata` → verified; forgery cannot override
  an authoritative false.
- `test_forged_user_metadata_token_cannot_attach_to_a_strangers_account` — a
  genuinely-signed token whose verified flag lives only in `user_metadata`,
  through the **real** HS256 verifier, lands on its own account, never the
  victim's.
- `test_confirmed_web_email_does_attach_through_the_real_verifier` — positive
  control: an authoritatively-confirmed address still converges.
- `test_email_password_login_threads_verification_and_converges` — a verified
  password login joins the person's existing canonical account.

## Tests

- **Backend:** `apps/backend/tests/test_account_continuity.py` (new, 12 cases):
  iOS→web convergence, web→iOS convergence, unverified-web-email non-merge,
  unverified-native-email non-merge, single-owner attach, never-rewrite-a-subject,
  ambiguous-address refusal, empty/malformed address, and the four
  verification-authority cases listed under Change 3.
  Full suite: **990 passed, 1 skipped** (`python3 -m pytest -q`, ~73s). No
  regressions from the resolver/`social_auth`/verification-authority changes.
- **Web:** `apps/web/src/lib/apple-oauth-binding.test.ts` (new, 7 cases:
  fail-closed default, sibling-id rejection, Tono-shape acceptance, lookalike
  rejection, expected-id strict equality, copy content) and three added cases in
  `account-payment-history-ui-contract.test.cjs` (separate Apple gate, fallback
  copy, and a **no-foreign-client-id-in-source** guard). Full web suite:
  **109 passed, 0 failed** (`npm test`).
- **Web production build:** green in all four env scenarios above.

---

## Native surfaces (audited, unchanged — already implemented)

No iOS/Android source was changed; the continuity fix is server-side and
benefits both automatically. **Build 125 (iOS) and Android Build 120 are
preserved.** Verified present in source:

| Capability | Web | iOS | Android |
|---|---|---|---|
| Apple sign-in (product-branded) | gated seam (Ch.1) | native `ASAuthorization` (own bundle) | native |
| Google sign-in | Supabase OAuth | `GoogleSignIn` | Credential Manager |
| Passkey enroll/sign-in | ✓ | ✓ | ✓ |
| Email register/login + password | ✓ | `TonoBackend.registerWithEmail/signInWithEmail` | `AccountSheet` |
| **Password show/hide toggle** | `PasswordField` | eye toggle w/ a11y (`OnboardingEntryPointsView`) | `passwordVisible` toggle |
| Forgot / reset / resend | ✓ | ✓ | ✓ |
| Canonical account (server-owned) | `/v1/auth/web` | `/v1/auth/apple`,`/google` | same |

Native Apple/Google use each app's own client identity, verified server-side
against `APPLE_CLIENT_ID`/`GOOGLE_CLIENT_ID`; no sibling client id appears in any
compiled native artifact (repo-wide `grep -i parentscript` finds only two design
comments and one test host-list — none is a client id).

---

## Status ledger

| Level | Status | Note |
|---|---|---|
| SOURCE_IMPLEMENTED | **YES** | Apple fail-closed gate + bidirectional verified-email convergence, with tests and green web build. |
| PROVIDER_CONFIGURED | **NO** | Requires the operator to (a) re-bind the Supabase Apple provider to Tono's Services ID and set `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID`, and (b) set `APPLE_CLIENT_ID`/`GOOGLE_CLIENT_ID`/`TONO_APPLE_ROOT_CA_PEM`/`TONO_GOOGLE_SERVICE_ACCOUNT_JSON` server-side. `https://api.tonoit.com/health` still reports `apple_configured:false`, `google_play_configured:false`. Not touched here. |
| LIVE_AUTH_VERIFIED | **NO** | No deploy performed; unverifiable without the provider config above. |
| PAYMENT_VERIFIED | **NO** | `stripe_configured:true` only; no purchase gate weakened; native billing untouched. |
| SIGNED_DEVICE_VERIFIED | **NO** | No archive/build/upload; Build 125 and Android Build 120 preserved. |

## Known gap deliberately NOT half-built

Server-owned **rewrite history across device/reinstall** is still device-local
on web (`history-store.ts` / localStorage; the history page honestly says
"stored on this device only"). A cross-platform server-owned history projector
is a large, separate change with its own privacy-control surface; implementing it
partially would risk the "no empty dashboards / no false authority" rule. Left
for a dedicated pass and flagged here rather than silently claimed.
