# Backend data migrations

`20260724_lifetime_stripe_trial` adds a sticky reservation timestamp to the
canonical account and anonymous device fallback. Existing Stripe customer or
subscription history is conservatively backfilled as already reserved.

Apply the matching SQLite or PostgreSQL script while checkout traffic is
stopped. The active SQLite application also applies the additive columns and
backfill idempotently during startup.

Rollback is code-only: deploy the prior application while retaining both
columns and their values. Dropping or clearing either column reopens free-trial
eligibility and is therefore unsafe. A later forward deploy must preserve the
timestamps; cancellation, expiration, refund, deletion/tombstoning, customer
reassignment, reinstall, and account linking must never reset them.
