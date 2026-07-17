# Trial-only release gates

Do not ship any client until every external gate below is verified in the live
store environment. Local configuration proves UI and contract behavior only;
it does not create store eligibility or a billable subscription.

## App Store Connect

- Product IDs `com.tonoit.pro.monthly` and `com.tonoit.pro.yearly` must exist in
  the same subscription group.
- Both products must have an introductory offer of exactly 7 days at no charge.
- US base prices must be exactly USD $3.99/month and $39.99/year. StoreKit
  localized display prices and introductory-offer eligibility are authoritative
  at runtime.
- Verify purchase authorization, day-8 conversion, cancellation, billing
  failure, restore, manage/cancel, Terms, and Privacy in sandbox review flows.
- Configure `APPLE_ROOT_CA_PEM` with Apple's trusted root certificate on the
  backend; signed StoreKit transactions fail closed without it.

## Google Play

- Both matching monthly and annual subscription products must expose an
  eligible zero-price 7-day offer, followed by localized renewal pricing based
  on USD $3.99/month and $39.99/year.
- Production backend verification for Play purchase tokens must be configured
  with `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `GOOGLE_PLAY_PACKAGE_NAME`, and the
  exact `GOOGLE_PLAY_TRIAL_OFFER_IDS`. Until it is, Android purchases
  intentionally fail closed and must not ship.
- Verify purchase acknowledgement, day-8 conversion, cancellation, payment
  failure, restore, and manage-subscription flows with Play test accounts.

## Stripe

- `STRIPE_PRICE_PRO_MONTHLY` and `STRIPE_PRICE_PRO_YEARLY` must point to exact
  recurring USD $3.99/month and $39.99/year Prices.
- Set the same high-entropy `TONO_WEB_AUTH_SECRET` on the web deployment and
  backend. The Supabase callback uses it only server-to-server to link the
  verified web subject to a durable Tono account; checkout fails closed for an
  unlinked device.
- Checkout must require explicit customer authorization before the 7-day trial
  begins. The backend asks Stripe for prior subscriptions before attaching the
  trial, and `/v1/offer` returns the selected account's live Stripe price and
  eligibility for localized web display. Confirm both new and returning-customer
  paths against Stripe test mode before production traffic.
- Configure and verify the signed webhook secret. Exercise durable
  `trialing -> active`, `past_due`, cancellation/deletion, and unknown-status
  fail-closed paths before production traffic.

Promo/coupon access is a separately granted, non-auto-renewing entitlement. It
must never be represented as a store trial or a free tier.
