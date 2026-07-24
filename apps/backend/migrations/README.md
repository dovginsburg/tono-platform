# Backend data migrations

`20260724_lifetime_stripe_trial` adds a monotonic account/customer/fingerprint
scope ledger, a unique customer-binding registry, and an auditable conflict
table. Existing Stripe-touching accounts, devices, purchases, and tombstones
are conservatively backfilled as consumed.

Apply the matching SQLite or PostgreSQL script while checkout traffic is
stopped. The active SQLite application also applies the additive schema and
backfill idempotently during startup.

Rollback is code-only: deploy the prior application while retaining both
ledger rows and bindings. Deleting or rewriting consumed rows reopens
free-trial eligibility and is unsafe.

Legacy trade-off: paid-only customers are marked consumed too. Historical data
cannot prove whether an old Stripe customer used a trial, so denying a small
number of first trials is safer than granting every historical trialer another
14 days.
