# Owner action — enable Apple Pay + Google Pay on the Tono web checkout

**Code side is DONE and tested. What remains is provider-side enablement, which
requires a human Stripe Dashboard login this session does not have.**

Directive (2026-07-25): every Amazed Labs product website offers one unified web
checkout where eligible buyers can pay by **card, Apple Pay, or Google Pay**.

---

## 1. What is already true in code

`apps/backend/payments.py` → `create_checkout_session` no longer pins
`payment_method_types`. Omitting it is what puts the session on Stripe's
**automatic payment methods**: Stripe applies the Dashboard-configured set and
filters it per request by currency, amount, customer country, and the buyer's
browser/device.

Guarded by `apps/backend/tests/test_web_wallet_checkout.py` (13 tests, red-capable —
restoring the pin fails 3 of them).

**The wallet model, stated exactly because it is easy to get wrong:**

| Surface | Apple Pay | Google Pay |
|---|---|---|
| **Web (tonoit.com)** | Stripe wallet on hosted Checkout. **Not StoreKit.** | Stripe wallet on hosted Checkout. **Not Play Billing.** |
| **iOS app** | StoreKit 2 — separate native rail | n/a |
| **Android app** | n/a | Google Play Billing — separate native rail |

All three rails converge on the ONE server-authoritative entitlement
(`store.py::User.is_pro`). **Google Play Billing must never be presented or
labelled as a website payment method** — the web copy already gets this right
(`apps/web/src/app/privacy/page.tsx` says "Stripe (web) or App Store / Google Play
(mobile)").

---

## 2. Exact bounded action (requires a human Stripe login)

**Stripe Dashboard → Settings → Payment methods** (in the **live** account, and
in **test** first):

1. Enable **Apple Pay**.
2. Enable **Google Pay**.
3. Leave **Card** enabled (both wallets are card-backed; card is also the
   fallback for ineligible browsers/devices).

That is the whole change. Nothing else in the Dashboard needs touching, and no
price, product, or trial setting may be altered.

### Domain registration — when it IS and is NOT needed

- **Not needed today.** Tono uses **Stripe-hosted Checkout**: the buyer is
  redirected to `checkout.stripe.com`, which is Stripe's own domain and is
  already registered with Apple. Verified by
  `test_web_checkout_is_stripe_hosted_so_wallets_need_no_domain_registration`.
- **Needed only if** the flow later moves to an embedded **Payment Element** or
  **Express Checkout Element** on `tonoit.com`. Then register `tonoit.com` (and
  `www.tonoit.com`) under **Settings → Payment methods → Payment method domains**,
  which serves the `apple-developer-merchantid-domain-association` file for you.
  Do not pre-register; it is inert until an Element is embedded.

---

## 3. How to verify after enabling (no real charge)

Use Stripe **test mode** with `STRIPE_SECRET_KEY` pointed at the test key.

| Check | How | Expected |
|---|---|---|
| Card baseline | Any browser → start checkout | Card form renders; `4242…` completes |
| Apple Pay eligibility | **Safari on macOS/iOS** with a card in Wallet | Apple Pay button in the express row |
| Google Pay eligibility | **Chrome** signed into a Google account with a card | Google Pay button in the express row |
| Fallback | Firefox, or Safari with an empty Wallet | **No wallet button, card form still works** — this is correct, not a bug |
| HTTPS requirement | — | Wallets only appear on HTTPS; `checkout.stripe.com` is always HTTPS |
| Entitlement convergence | Complete a test-mode wallet purchase | `/v1/me` → `is_pro: true`, same as a card |
| No duplicate trial | Second checkout on the same account | No `trial_period_days` re-requested |
| Cancel | `/v1/portal` → cancel | Entitlement revoked on `customer.subscription.updated` |

Wallet **rendering** is Stripe's, on Stripe's domain — it cannot be asserted from
this repository. The above are human/browser checks; everything on our side of
the boundary is covered by the automated tests in §1.

---

## 4. Accessibility, error states, and honest copy

- Wallet buttons are rendered and labelled by Stripe Checkout, which ships its
  own accessible markup and localisation. We do not restyle or re-label them.
- `ProCheckoutButton` keeps the buyer on-page for any non-200, showing an inline
  error rather than a dead redirect, and refuses double-submit while busy.
- **Localised price:** Stripe Checkout renders the amount and currency from the
  Price object, in the buyer's locale. Our marketing copy states the canonical
  USD amounts ($3.99/mo, $39.99/yr) — if non-USD Prices are ever added, that copy
  must gain a "prices shown in your local currency at checkout" qualifier.
- **Renewal/cancellation text is already honest and present** on `/pricing`,
  `/privacy`, and the footer: 14-day free trial, then $3.99/mo or $39.99/yr,
  auto-renews unless cancelled, cancel anytime via the billing portal.

---

## 5. What is NOT done and must not be faked

- Wallets are **not yet enabled** in the Stripe Dashboard — that is this action.
- **No live wallet purchase has been made or observed.** No Stripe API call was
  issued from this session with real credentials.
- Until §2 is done, a buyer sees the card form only. Nothing is broken; the
  wallet row is simply empty.

## 6. Rollback

Disabling either wallet in the Dashboard reverts the buyer experience
immediately, with no code change and no effect on existing subscriptions. The
code change itself is reverted by restoring `payment_method_types=["card"]` —
which the tests will then fail, by design.
