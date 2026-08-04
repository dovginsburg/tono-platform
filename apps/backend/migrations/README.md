# Backend data migrations

`20260724_lifetime_stripe_trial` adds a monotonic account/customer/fingerprint
scope ledger, a unique customer-binding registry, and an auditable conflict
table. Existing Stripe-touching accounts, devices, purchases, and tombstones
are conservatively backfilled as consumed.

Apply the matching SQLite or PostgreSQL script while checkout traffic is
stopped. The active SQLite application also applies the additive schema and
backfill idempotently during startup.

`20260803_revenuecat_canary` adds the RevenueCat canary seam: a durable,
product-specific webhook inbox (`revenuecat_events`, with a
received/processed/failed/dead_letter state machine + retry attempts) and a
shadow-comparison ledger (`revenuecat_shadow_observations`). It is additive and
safe to run live — no existing table is modified. RevenueCat itself reuses the
shared `provider_purchases` (`provider='revenuecat'`) and `entitlement_grants`
tables, so there is exactly one deterministic entitlement writer; the canary is
gated by `TONO_REVENUECAT_MODE` (off | shadow | authoritative). The live SQLite
app also creates these tables idempotently at startup. Rollback is code-only:
retaining the tables is harmless when RevenueCat is `off`.

`20260804_revenuecat_shadow_flip_eligibility` adds a nullable `store_source`
column to `revenuecat_shadow_observations` and backfills it from the durable
`revenuecat_events` row each observation was derived from (event_id join, with a
raw event-payload fallback). It is additive and safe to run live — the
append-only ledger, including promotional observations, is preserved. This fixes
a flip-gate defect: a RevenueCat `PROMOTIONAL` admin grant makes RevenueCat
active with no store purchase, so in `shadow` mode it legitimately disagrees with
the (correct) free legacy projection and was permanently pinning `shadow_clean`
false even on a healthy integration. With `store_source` recorded, the
`shadow -> authoritative` decision is computed from real store-parity canaries
(App Store/Play/Stripe/RC Billing/Test Store/...) only; promotional rows stay in
lifetime diagnostics but are excluded from the flip, and an unclassifiable store
fails closed. The live SQLite app applies the column additively at startup (the
`ALTER` is suppressed if present) and backfills each row — including recovery
from the raw event payload — via `_backfill_revenuecat_shadow_store_source`.
Rollback is code-only: the extra column is harmless to prior code.

Rollback is code-only: deploy the prior application while retaining both
ledger rows and bindings. Deleting or rewriting consumed rows reopens
free-trial eligibility and is unsafe.

Legacy trade-off: paid-only customers are marked consumed too. Historical data
cannot prove whether an old Stripe customer used a trial, so denying a small
number of first trials is safer than granting every historical trialer another
14 days.
