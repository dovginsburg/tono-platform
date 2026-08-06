# Tono — Stripe dedicated-account operator manifest (2026-08-06)

**Purpose.** One exact, operator-executable manifest to bring Tono's **dedicated**
Stripe account from *activated-but-empty* to *runtime-bound*, derived **only**
from canonical source:
- `packages/contracts/commercial-catalog.v1.json` (approved commercial terms), and
- `apps/backend/payments.py` + `apps/backend/catalog.py` (runtime behavior).

Nothing here is invented. Display amounts are the already-approved catalog
values; the manifest records env-var **names**, never secret values.

**Ezra owns every mutation and verification below. This lane did not retrieve the
secret, did not call Stripe, and did not change any Stripe object.**

---

## ✅ STATUS — EXECUTED by operator (2026-08-06); ONE deploy gate remains

The catalog/runtime/webhook below were **created and bound live** on
`acct_1U1CzyLZbknfauDy` (receipt: `tono-live-stripe-runtime-webhook-20260806.md`).
The "to create / 0 products / empty" framing in §1–§2 is the **pre-execution
plan** — retained for provenance; the live objects now exist:

| Object | Live id / value | Matches manifest |
|---|---|---|
| Product | `prod_V1VR4KF7SXeu7Z` (Tono Pro, active, marker=stripe_pro) | ✓ |
| Monthly Price → `STRIPE_PRICE_PRO_MONTHLY` | `price_1U1SQhLZbknfauDyOQn0OWxV` (USD 399/mo, `lookup_key=tono_pro_monthly`, trial-less) | ✓ |
| Yearly Price → `STRIPE_PRICE_PRO_YEARLY` | `price_1U1SQhLZbknfauDyCxNTW15g` (USD 3999/yr, `lookup_key=tono_pro_yearly`, trial-less) | ✓ |
| Webhook | `we_1U1STvLZbknfauDyTVGo4aPJ` @ `https://api.tonoit.com/v1/stripe/webhook`, livemode, all 11 events; invalid-sig → 400 | ✓ |
| Render env | `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, both price vars, `TONO_STRIPE_ACCOUNT_ID=acct_1U1CzyLZbknfauDy` installed; deploy `dep-d9q9q37avr4c73b3010g` live; `/health` `stripe_configured=true` | ✓ |

**⛔ OPEN GATE — backend build divergence.** Production still serves an **older
build**: `/health` `canonical_sha=185dc7b1…` and **`/v1/stripe/readiness` → HTTP
404** (independently re-probed 2026-08-06). That build predates the readiness
endpoint **and** the dedicated-account identity guard (both added in branch
commit `02a8ee3`, on origin through `c95d18a`). Live Checkout/webhook already
function on the isolated key (limited blast radius), but **runtime acceptance is
NOT complete** until an accepted backend build containing `02a8ee3` is deployed
(GHCR image by canonical SHA → Render repoint) and §5 passes on production.
Deploying is **safe**: Render's `TONO_STRIPE_ACCOUNT_ID` equals the key's account,
so `_require_tono_stripe_account()` passes (does not 503). This is an
operator/deploy action — not done or pushed by this lane.

---

## 0. Account identity & custody (pin this first)

| Field | Value |
|---|---|
| **Dedicated Tono account** | `acct_1U1CzyLZbknfauDy` (business name "Tono", US) |
| Activation (live readback 2026-08-06) | `details_submitted=true`, `charges_enabled=true`, `payouts_enabled=true` |
| Current catalog state | **0 products, 0 prices, 0 webhooks, 0 customers, 0 subscriptions** |
| Secret custody | Keychain service `tono-stripe-restricted-live`, account `amazed-labs-ezra` — **restricted live key**; never printed/committed |

> 🚫 **Isolation.** The legacy/contaminated account `acct_1TRJaBQ93BpfjtrE`
> ("Dov Ginsburg MD PLLC", mixed TandemPaws/ParentScript/Tono catalog) and any
> sibling-product account **must never** be used, bound, or mutated for Tono.
> The backend's `_require_tono_stripe_account()` fails closed (503) unless the
> configured key's live account **equals** `TONO_STRIPE_ACCOUNT_ID` — set that to
> `acct_1U1CzyLZbknfauDy` so a wrong key can never bill Tono users.

---

## 1. Products & Prices to create (on `acct_1U1CzyLZbknfauDy`)

**Canonical entitlement:** exactly ONE — `pro` ("Tono Pro", unlimited rewrites).
Model as **one Product with two recurring Prices** (the catalog lists month/year,
both → entitlement `pro`; there is no per-provider or duplicate plan).

**Product**
| Field | Value |
|---|---|
| name | `Tono Pro` |
| (optional) metadata | `entitlement=pro`, `catalog_version=1.0.0`, `tono_product_marker=stripe_pro` — traceability only; source does not read Product metadata |

**Prices** (currency USD; **recurring**; amounts are the approved catalog display values)
| Interval | unit_amount | currency | recurring.interval | Runtime env var that must hold this Price ID |
|---|---|---|---|---|
| Monthly | `399` (= $3.99) | `usd` | `month` | **`STRIPE_PRICE_PRO_MONTHLY`** |
| Yearly | `3999` (= $39.99) | `usd` | `year` | **`STRIPE_PRICE_PRO_YEARLY`** |

**Trial — do NOT put it on the Price.** The 14-day free trial (catalog
`trial.days=14`, `P2W`) is applied by the server at Checkout time via
`subscription_data.trial_period_days = 14` (`payments.py`, the single web-trial
authority). If the Price also carried a trial, Stripe would **stack a second
trial** — the Price objects must stay **trial-less**.

**Lookup keys — operator-optional.** Source resolves Prices by the env-var Price
**ID**, not by `lookup_key`. If you want stable readback handles, set
`lookup_key=tono_pro_monthly` / `tono_pro_yearly`; nothing in code depends on
them, so this is convenience only, not a required commercial term.

---

## 2. Webhook endpoint to create

| Field | Value (source-derived) |
|---|---|
| **URL** | `https://api.tonoit.com/v1/stripe/webhook` (router prefix `/v1` + `POST /stripe/webhook`; prod API base = Android release `BACKEND_URL`) |
| API version | account default (handler reads `event["type"]`/`data.object` generically) |
| Signing secret → env | the endpoint's `whsec_…` goes into **`STRIPE_WEBHOOK_SECRET`** (verified via `stripe.Webhook.construct_event`; a bad/absent signature ⇒ 400, fail-closed) |

**Exact events the handler consumes** (`_handle_all_stripe_events`) — enable
precisely these; anything else is logged and ignored:
- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `checkout.session.expired`
- `invoice.payment_succeeded`
- `invoice.payment_failed`
- `charge.refunded`
- `charge.dispute.funds_withdrawn`
- `charge.dispute.funds_reinstated`
- `charge.dispute.closed`

---

## 3. Runtime environment (set on Render backend — NOT committed)

| Env var | Holds | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | the restricted **live** secret key value | from Keychain `tono-stripe-restricted-live`; operator installs, never echoed |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…` from §2 | enables signature verification |
| `STRIPE_PRICE_PRO_MONTHLY` | monthly Price ID from §1 | `price_…` |
| `STRIPE_PRICE_PRO_YEARLY` | yearly Price ID from §1 | `price_…` |
| `TONO_STRIPE_ACCOUNT_ID` | `acct_1U1CzyLZbknfauDy` | **non-secret**; the isolation allowlist. Without it the guard is a no-op — set it. |

All Stripe reads/writes use `stripe.api_key = STRIPE_SECRET_KEY`; when the key is
absent every payment route already returns **503 fail-closed**.

---

## 4. Checkout & Portal — provider-side requirements

**Checkout** (`stripe.checkout.Session.create`, source-fixed shape):
- `mode="subscription"`, `line_items=[{price: <resolved Price ID>, quantity: 1}]`
- `payment_method_types` is deliberately **unset** → Stripe applies
  **Dashboard-configured automatic payment methods**. To offer card + **Apple Pay**
  + **Google Pay** (both are Stripe *web wallets* on hosted Checkout — NOT
  StoreKit / NOT Play Billing), enable them in **Dashboard → Settings → Payment
  methods**. Stripe-hosted Checkout runs on `checkout.stripe.com`, so **no**
  payment-method-domain registration is needed (that's only for an embedded
  Element on `tonoit.com`).
- Server sets `metadata` + `subscription_data.metadata = {tono_account_id,
  tono_device_id}` and `client_reference_id = <canonical account UUID>`. These
  are set **at runtime by the backend**, not configured on the Price — the
  webhook resolves the account from `tono_account_id`. Anonymous web checkout is
  refused (browser signs in first).
- Default `success_url=/welcome-pro?s=1`, `cancel_url=/pricing` (on the branded
  web origin).

**Customer Portal** (`stripe.billing_portal.Session.create`): **activate the
Customer Portal** in **Dashboard → Settings → Billing → Customer portal** (allow
cancel/update payment method), else portal-session creation errors. Return URL is
server-allowlisted to `/app/account`.

---

## 5. Readback / acceptance (after operator wiring)

1. **Non-secret readiness probe:** `GET https://api.tonoit.com/v1/stripe/readiness`
   → expect:
   ```
   secret_key_configured:true  webhook_secret_configured:true
   price_monthly_configured:true  price_yearly_configured:true
   expected_account_id:"acct_1U1CzyLZbknfauDy"  account_identity_verified:true
   account_id:"acct_1U1CzyLZbknfauDy"  catalog_version:"1.0.0"  ready:true
   ```
2. **Account identity:** `stripe.Account.retrieve()` on the configured key returns
   `acct_1U1CzyLZbknfauDy` with `charges_enabled=true` (already true).
3. **Trial correctness:** create a live/test Checkout for `month` → the resulting
   Subscription shows a **14-day** trial and the Price itself has **no** trial.
4. **Webhook delivery:** Stripe Dashboard → the endpoint shows 2xx on
   `checkout.session.completed`; backend projects `provider_purchases →
   entitlement_grants` (`store.py User.is_pro`), no duplicate grant.

## 6. Rollback (safe; account currently has 0 customers/subscriptions)

- **Disable runtime:** unset `STRIPE_SECRET_KEY` (and/or the price/webhook vars)
  on Render → readiness `ready:false`, all payment routes 503 fail-closed. No
  charge can occur.
- **Webhook:** disable/delete the endpoint in Dashboard (no customer impact).
- **Catalog:** **archive** (set `active=false`) the Prices/Product rather than
  delete — reversible and preserves references. With 0 existing customers there
  is nothing to migrate.
- **Isolation tripwire:** if `account_identity_verified` ever reads `false`, a
  non-Tono key is installed — checkout is already 503'ing; remove the wrong key.

---

### Provenance
Commercial terms: `commercial-catalog.v1.json` (catalog_version `1.0.0`; prices
month `3.99` / year `39.99` USD; trial `14` days / `P2W`; one `pro` entitlement).
Runtime shape: `apps/backend/payments.py` (`_price_for`, checkout `session_kwargs`,
`_require_tono_stripe_account`, `stripe_readiness`, `_handle_all_stripe_events`,
`billing_portal`). Account activation + custody: capability receipt
`/private/tmp/tono-stripe-dedicated-key-capability-20260806.md`. Enforced by the
backend suite (`test_commercial_catalog`, `test_stripe_dedicated_account_isolation`
9/9, magic-link/lifecycle) — **1197 passed / 2 skipped** at HEAD `c95d18a`.
