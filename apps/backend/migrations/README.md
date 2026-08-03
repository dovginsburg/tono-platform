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

Rollback is code-only: deploy the prior application while retaining both
ledger rows and bindings. Deleting or rewriting consumed rows reopens
free-trial eligibility and is unsafe.

Legacy trade-off: paid-only customers are marked consumed too. Historical data
cannot prove whether an old Stripe customer used a trial, so denying a small
number of first trials is safer than granting every historical trialer another
14 days.
