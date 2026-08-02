# Account · Payment · History — Surface × Capability Matrix

Reconstructed from HEAD `2f2ef815` (the offline-layout successor lineage) on 2026-08-02.
Legend: **WORKING** = implemented and unblocked · **BLOCKED** = code present but gated
(fail-closed 503 / capability absent / SDK unlinked) · **MISSING** = not present.

Canonical authority is the FastAPI backend (`apps/backend`). The server-issued
`accounts.id` UUID is the only entitlement principal; device/install IDs
(`users.device_id`) are aliases that link to it. Supabase is used only as an
external identity provider (passwords, verification/reset mail) and for the
`tono_private` auth-isolation audit schema — never as this server's runtime store.

Baselines at reconstruction: backend `pytest` **966 passed / 1 skipped**; web
`npm test` **83 passed**.

## Legend of founder requirements

1. Product-branded Sign in with Apple + Google OAuth; capability-gated/fail-closed.
2. Accessible show/hide control on every password field.
3. Passkeys where supported, with honest fallback UX.
4. Canonical server-issued account owns private data/history/entitlement; device IDs are aliases; convergence without email-only silent merges.
5. Complete forgot/reset password lifecycle.
6. Payments by platform bound to canonical account + one server-authoritative entitlement ledger, with full lifecycle.
7. User-owned longitudinal history/progress with durable truth, chronology, trends, correction/delete/export, second-device continuity, account-switch cache isolation, no raw IDs / vanity-only totals.
8. Release-quality responsive/accessibility UX.

## Matrix

| Capability | Backend (authority) | Web | iOS (host + ext) | Android |
|---|---|---|---|---|
| **1. Apple sign-in** | WORKING — `/v1/auth/apple`, JWKS RS256, aud/iss + nonce verified, 503 if unconfigured (`social_auth.py:87-121`, `server.py:853-868`) | WORKING (button) — `login/page.tsx:255-270`; ⚠️ **not** capability-gated (renders unconditionally, fails at click) | WORKING — native `SignInWithAppleButton`, server-verified (`OnboardingEntryPointsView.swift:587-626`) | MISSING (parity-deferred; email/password only) |
| **1. Google sign-in** | WORKING — `/v1/auth/google`, JWKS, 503 if unconfigured (`server.py:871-882`) | WORKING (button); ⚠️ same non-gated caveat | BLOCKED — code present but `#if canImport(GoogleSignIn)` and SDK unlinked ⇒ button absent (fail-closed) (`OnboardingEntryPointsView.swift:609-649`) | MISSING |
| **2. Password show/hide** | n/a (server brokers to Supabase, never stores/handles password material) | **MISSING** on all 3 fields (`login/page.tsx:348`, `reset-client.tsx:91,110`) | **MISSING** (`OnboardingEntryPointsView.swift:663-671`) | **MISSING** (`AccountSheet.kt:159-171`) |
| **3. Passkeys** | WORKING — full WebAuthn ceremony set, 503 if unconfigured (`passkeys.py`), in-memory challenge store (single-worker) | WORKING + fail-closed — `PasskeyLoginButton.tsx`, `account/PasskeyManager.tsx`, 503 surfaced honestly | MISSING (honest fallback: Apple + email) | MISSING (honest fallback: email) |
| **4. Canonical account / no silent merge** | WORKING — `accounts.id` UUID PK; `apple_sub/google_sub/supabase_sub` UNIQUE; verified-email partial-unique; `provider_subject`; `_resolve_provider_signin` (`server.py:785-850`, `store.py:66-95,169-217`) | WORKING — converges via `POST /v1/auth/web`, email persisted only when verified (`auth/callback/route.ts`, `docs/web-account-auth.md`) | WORKING — canonical accountID in shared keychain group, device-only (no iCloud sync), server sign-in converges (`SharedKeychain.swift`, `TonoBackend.swift:348-351`) | WORKING — device UUID alias, `account_id` from `/v1/me`, `setObfuscatedAccountId(accountId)` never device (`TonoBackend.kt:97-130`, `PlayBillingManager.kt:136-139`) |
| **5. Forgot/reset lifecycle** | WORKING (request half) — `/v1/auth/email/reset` → Supabase recover; completion delegated to web (`server.py:1538-1578`, `email_auth.py`) | WORKING (completion) — recovery callback → `/auth/reset` → `updateUser` → landing (`auth/callback/route.ts:131-136`, `auth/reset/*`, `api/auth/password`) | WORKING (request) — `requestPasswordReset` → emailed link; completion via web (`TonoBackend.swift:449-547`) | WORKING (request) — `/v1/auth/email/reset` (`TonoBackend.kt:289-359`); completion via web |
| **6. Payments bound to account** | WORKING — Stripe checkout/portal/webhook full lifecycle; Apple App Store Server + Google Play verification; one `entitlement_grants` ledger; 409 on cross-account; BLOCKED to 503 until provider env present (`payments.py`, `app_store.py`, `google_play.py`) | WORKING — Stripe checkout/portal/entitlement read-back, fail-safe `/v1/me` (`ProCheckoutButton`, `ManageBillingButton`, `CheckoutSuccessClient`) | WORKING — StoreKit 2, `appAccountToken`=accountID, server-verified, restore, Build-122 fail-closed initiation gate intact (`StoreKitManager.swift`) | WORKING — Play Billing 6, server-verified, restore, entitlement ignores local state (`PlayBillingManager.kt`, `BillingContract.kt:19-23`) |
| **6a. Payment/billing history read** | **MISSING** → *added this change*: `list_entitlement_grants` existed (`store.py:4490`) but no route. New `/v1/account/payment-history`. | **MISSING** → *added*: account-page billing timeline | **MISSING** → *added*: payment-history view | **MISSING** → *added*: payment-history screen |
| **7. Longitudinal progress** | WORKING (read) — `/v1/digest` account-scoped trends; content-free telemetry (`usage_log`,`axis_events`,`improvement_events`). No raw message content stored by design. | BLOCKED — local-only `localStorage` history, no server progress surface; *fixed*: account isolation + export | WORKING (read) — "This Week" pulls `/v1/digest`; local 5-entry draft ring | WORKING (read) — `DigestScreen` pulls `/v1/digest`; `DRAFT_HISTORY`/`RECENT_SESSIONS` declared-unused |
| **7a. Account-switch cache isolation** | WORKING — `response_cache` keyed by full canonical input hash (`test_response_cache_isolation.py`) | **BLOCKED** → *fixed*: global `tono:history` key not per-account nor cleared on signout | **BLOCKED** → *fixed*: `draftHistory`/memories not cleared on signOut | **BLOCKED** → *fixed*: local memories not cleared on signout |
| **7b. Correction / delete / export** | Account DELETE tombstones (`/v1/account`); registration history owner-scoped read | Delete/clear present locally; *added*: export | MISSING → *added*: export/clear on payment+draft history | MISSING → *added*: clear |
| **7c. No raw IDs / vanity totals** | n/a | **BLOCKED** → *fixed*: raw uid leak `editor-client.tsx:415` | WORKING (no raw IDs shown) | WORKING |
| **8. Responsive / a11y / Dynamic Type / offline** | n/a | BLOCKED — breakpoints yes, px-only type (0 rem/clamp), no real offline detection | WORKING — `relativeTo:` Dynamic Type, `TonoConnectivity` offline, measure-based iPad column (iPad deep adaptation deferred) | PARTIAL — Compose scroll/adaptResize; some hardcoded colors, icon `contentDescription=null` |

## Central gap (this worktree's namesake)

Purchase and entitlement data is **fully modeled** server-side
(`provider_purchases`, `entitlement_grants`, `stripe_customer_bindings`,
`stripe_trial_ledger`) and mutated correctly by every provider path, but there
was **no read contract** exposing an account's payment/subscription timeline.
`store.list_entitlement_grants(account_id)` existed (`store.py:4490`) yet was
wired to no route; the only account-history endpoint was
`/v1/account/registration-events` (auth lifecycle only). This change adds the
owner-scoped billing-history read surface end-to-end and the client views that
consume it.

## Re-audit pass (2026-08-02, usefulness review follow-up)

A second pass re-audited the tree against the Fable usefulness review and the
competitor/integration briefs, then fixed the findings still valid:

- **Pre-auth interactive demo** (`web/src/app/DemoRewrite.tsx`, wired into
  `page.tsx`): the landing hero's static preview is now an interactive canned
  sample — fixed draft, precomputed four-tone output, a real "rewrite" beat, and
  no backend call. Captioned "canned sample · not a live rewrite"; no anonymous
  rewrite path is exposed.
- **Honest signed-in history empty state** (`app/app/history/page.tsx`): explains
  device-local storage and the second-device expectation ("a new browser or
  phone starts empty here, even though your account, plan, and billing follow
  you everywhere"). No server sync of raw rewrite text was added — local-only is
  kept by design.
- **`free` plan label removed** (`account/page.tsx`): a non-Pro account now reads
  "no active plan", not "free" (there is no free tier).
- **Fake `saved` state removed** (`app/app/editor-client.tsx`): the draft is not
  persisted, so the composer no longer claims "saved · just now" / "draft
  auto-saved"; only completed rewrites are saved to on-device history.
- **Verified payment amounts** (backend `store.py`/`payments.py`/`server.py`,
  clients web/iOS/Android): `provider_purchases` gains nullable `amount_minor`
  (integer minor units) + `currency`, captured ONLY from Stripe's authoritative
  recurring price. Apple/Google rows stay null and render no price — never a
  fabricated amount, still no raw transaction ids.
- **Respond in the draft's language** (`analyze.py`): both coach and read system
  prompts now instruct the model to answer in the same language as the draft.
  No language-picker suite was added; this is language preservation, not a
  translation feature.
- **Cross-platform billing home** is explicit: history is unified per account and
  readable natively on web, iOS and Android; a subscription is managed where it
  was bought (Apple ID subscriptions / web billing portal / Google Play). iOS
  payment-history view now states this.
- **Android IME is now a real typing keyboard** (`ime/keyboard/`, `ime/ui/KeyboardScreen.kt`,
  `ime/TonoImeService.kt`): the earlier pass honestly repositioned the IME as a
  rewrite companion *because it had no letter keys*. That gap is now closed. The
  keyboard implements a full alphabetic surface via `InputConnection` — QWERTY
  letters with a shift / one-shot / caps-lock machine, a 123/ABC numeric-symbol
  layer, space, backspace, host-adaptive return (Go/Search/Send/Next/Done or a
  newline), and the system keyboard switch — mirroring the proven iOS
  `KeyboardViewController`. The pure state machine (`KeyboardTypingState`),
  layout, and editor policies (`EditorPolicies`: secure-field / auto-cap /
  return-action) are framework-free and unit-tested. Coach and Read stay
  **explicit-tap only**, layered on top; typing is committed locally and is never
  logged, retained, sent, or used for analytics. In password / PIN fields the
  keyboard still types but the field-reading Coach/Read strip is replaced by an
  honest note and disabled — the same fail-closed posture as iOS
  `LiveToneEligibility`. The temporary "rewrite companion, not a full keyboard"
  copy has been removed now that it is no longer true. Real-device typing
  acceptance (keystroke capture on hardware) remains unearned — compilation and
  the JVM/instrumented tests do not prove it.

Deliberately NOT done (out of the product's honest scope this pass): server-sync
of rewrite history, an Android share-sheet/ProcessText "Coach this text" entry
(no host-app rewrite composer exists to land it honestly), calendar/`.ics` and
app-owned timers (optional, and a decorative timer does not serve the fast
rewrite job). iOS already ships the review-only "Coach this text" App
Intent/Shortcut/Share/iMessage entry points and neutral-content notifications.

## Honest external gates (not closeable in source)

- **Dashboard**: Stripe / Apple App Store Server API / Google Play Developer API
  credentials arrive only via environment; all three fail closed to 503 until
  present. `/health` surfaces `*_configured` booleans. iOS Google sign-in stays
  BLOCKED until the GoogleSignIn SDK is added to the Xcode project + a client ID
  is provisioned.
- **Physical device**: keyboard/share/iMessage runtime capture, StoreKit real
  purchase initiation, and iCloud-less cross-device convergence require a
  physical device; only simulator + source proof is available here.
- **Real payment**: no real charge is created; lifecycle is exercised with
  stubbed provider verifiers.
- **Release**: no store submission / dashboard mutation is performed.

## Deferred with honest fallback (feasible but out of this change's scope)

- iOS/Android **passkeys** (backend + web complete; native Credential Manager /
  `ASAuthorizationPlatformPublicKeyCredential` not added — fallback is Apple/email).
- Android **Google/Apple sign-in buttons** (email/password parity retained).
- Web **px→rem/clamp** typographic sweep for OS-level Dynamic Type (breakpoint
  responsiveness already present).
- Backend **Postgres versioned migration** of accounts/entitlement/purchase
  schema (currently the `store.py` SQLite SCHEMA; `schema/revision.txt` =
  `legacy-sqlite-unversioned`).
