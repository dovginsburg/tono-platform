# Tono RevenueCat canary — operator runbook

Status: **documentation only.** No secrets, keys, or live IDs appear here — only
environment-variable NAMES, the canary state machine, and the commands to verify
it. RevenueCat is the **first Tono canary** for a unified subscription lifecycle
across iOS, Android, and web/Stripe. ParentScript/TandemSkills and TandemPaws
follow only after this pattern is proven.

Companion documents (not duplicated here):

- `packages/contracts/commercial-catalog.v1.json` — the versioned catalog; the
  `revenuecat` provider block records env-var NAMES + the entitlement mapping.
- `docs/operations/tono-billing-launch-runbook.md` — the existing Stripe/Apple/
  Google launch checklist this canary sits alongside.

---

## 1. Design — one deterministic entitlement writer

RevenueCat is a **new provider** that flows into the SAME durable model every
other provider already uses:

```
RevenueCat webhook ─▶ revenuecat_events (durable inbox, keyed by RC event id)
                          │  idempotent processing (received→processed/failed/dead_letter)
                          ▼
                    provider_purchases (provider='revenuecat', append-only facts)
                          ▼
                    entitlement_grants  ◀── the ONE deterministic projection
                          ▼
                    store.py User.is_pro ── the ONE entitlement reader (/v1/me)
```

There is **no second entitlement authority**. RevenueCat never grants via a
client `CustomerInfo`; the clients treat CustomerInfo as observation only and keep
reading `/v1/me`. The RevenueCat **App User ID is the immutable Tono account UUID**
(`accounts.id`) — never an email, device id, installation id, anonymous RevenueCat
id, provider customer id, or cross-product person id.

---

## 2. Kill switch + shadow/rollback boundary

`TONO_REVENUECAT_MODE` (backend) is the canary state machine:

| Mode | Webhook | Entitlement writer | Use |
| --- | --- | --- | --- |
| `off` (default) | 503 (kill switch) | legacy only | RevenueCat dormant; clients do not configure the SDK. No source risk. |
| `shadow` | 200, records facts + a `revenuecat_shadow_observations` comparison vs legacy, **writes NO grants** | **legacy only** | Prove parity: compare RevenueCat's decision against the live projection with zero access impact. |
| `authoritative` | 200, **writes grants** | RevenueCat for its channels; legacy disabled for those channels | The deliberate cutover, per channel. |

**Rollback** is a config flip back to `shadow` (or `off`): grants already written
remain valid and expire naturally; no data is lost (the inbox is durable). There
is never indefinite dual authority and never a duplicate checkout — the existing
Stripe Checkout / StoreKit / Play Billing paths are unchanged and remain the buy
surfaces during the canary.

Reconciliation: `store.revenuecat_shadow_disagreements()` lists any RevenueCat-vs-
legacy disagreements (empty in a healthy shadow); the startup lifespan drains the
inbox via `revenuecat.reconcile_revenuecat(...)`.

---

## 3. Environment-variable NAMES (values set by the operator, never in source)

### Backend (Render service)
- `TONO_REVENUECAT_MODE` — `off` | `shadow` | `authoritative` (default `off`).
- `TONO_REVENUECAT_WEBHOOK_AUTH` — the Authorization header value configured in
  the RevenueCat dashboard webhook. **Required** for `shadow`/`authoritative` or
  the webhook 503s. Compared in constant time against the incoming `Authorization`
  header.
- `TONO_REVENUECAT_ENTITLEMENT_ID` — the RevenueCat entitlement identifier mapped
  to the canonical `pro` (default `pro`).
- `TONO_REVENUECAT_SECRET_API_KEY` — *optional* RevenueCat REST secret for the
  reconciliation re-query hook. The supplied credential is legacy v1 / Test Store,
  so the primary authority is the authenticated webhook; the re-query is a
  cross-check, not a gate.
- `TONO_REVENUECAT_PROJECT_ID` — *optional*, surfaced by readiness only.

### iOS (Info.plist, publishable key — safe in the client)
- `REVENUECAT_PUBLIC_SDK_KEY` — publishable `appl_…` key. `$()`-substituted;
  unresolved/empty ⇒ RevenueCat stays dormant (kill switch). Inject via build
  settings / xcconfig, exactly like `TONO_CANONICAL_SHA`.

### Android (BuildConfig field, publishable key)
- `REVENUECAT_PUBLIC_SDK_KEY` — publishable `goog_…` key. Empty by default
  (dormant). Inject per build/environment; never commit a real value.

### Web (publishable key — web checkout STAYS Stripe-hosted)
- `NEXT_PUBLIC_REVENUECAT_MODE` — `off` (default) | `shadow` | `authoritative`.
- `NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY` — publishable `rcb_…` web key.
  Required when the web mode is enabled (fails closed otherwise).

The web does **not** move to RevenueCat Billing or wallets — the existing Stripe
Checkout + Customer Portal (`/v1/checkout`, `/v1/portal`) and the trial / cancel /
refund semantics are unchanged. RevenueCat observes web subscriptions via its
Stripe integration, attributed to the canonical account UUID the backend stamps on
the Stripe Customer and subscription as the `tono_account_id` **metadata** field
(`apps/backend/payments.py`) — that metadata field is what the RevenueCat Stripe
app must map to its App User ID so web unifies with iOS/Android. (The Checkout
session's `client_reference_id` carries the *device* id, not the account UUID, so
it is not the field to map.)

---

## 4. Non-secret readiness + health

- `GET /v1/revenuecat/readiness` — booleans + public identifiers only:
  `mode`, `enabled`, `webhook_auth_configured`, `reconcile_requery_configured`,
  `writes_grants`, `entitlement_id`, `offering`, `product_ids`, `catalog_version`,
  `ready`. Never a secret value.
- `GET /health` — adds `revenuecat_mode` and `revenuecat_configured` (presence
  only).

---

## 5. Verification commands (run in this worktree)

- Backend: `cd apps/backend && python -m pytest` — includes
  `tests/test_revenuecat_canary.py` (28 hostile tests) and
  `tests/test_revenuecat_client_contract.py` (cross-client source contract).
- iOS build (CI-equivalent): `cd apps/ios && xcodebuild build -project Tono.xcodeproj
  -scheme Tono -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`.
- Android: `cd apps/android && ./gradlew testDebugUnitTest lintDebug assembleDebug`.
- Web: `cd apps/web && npm test` (node:test; no install).

---

## 6. Remaining provider gates (NOT code — the operator/Ezra owns these)

- Create the isolated RevenueCat **project for Tono** (one per product; never
  shared) and its **per-app publishable SDK keys** (`appl_`, `goog_`, web `rcb_`).
  The supplied private credential is **legacy v1** and the SDK key is a **Test
  Store** key; **v2 management access and per-app production keys are separate
  provider gates**.
- Configure the RevenueCat **entitlement** (`pro`), **offering** (`default`), and
  **packages** (`$rc_monthly`, `$rc_annual`) against the existing store products
  `com.tonoit.pro.monthly` / `com.tonoit.pro.yearly` and the connected Stripe
  prices — with the canonical 14-day trial / $3.99mo / $39.99yr contract.
- Configure the RevenueCat **webhook** to `POST /v1/revenuecat/notifications` with
  the shared Authorization value set as `TONO_REVENUECAT_WEBHOOK_AUTH`.
- Add the **RevenueCat iOS SPM package** (`purchases-ios`) in Xcode — the first
  SPM dependency in the project; until linked, the iOS code is a compiled no-op.
- Flip `TONO_REVENUECAT_MODE` `off → shadow`, confirm zero disagreements over a
  soak, then `shadow → authoritative` per channel. Do not claim end-to-end payment
  success until a real sandbox purchase has been observed through the webhook.
