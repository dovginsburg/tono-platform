-- SQLite forward migration for one lifetime Stripe trial.
-- Run transactionally while checkout traffic is stopped. Application startup
-- performs the data backfill with INSERT ... ON CONFLICT/INSERT OR IGNORE.
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS stripe_trial_ledger (
 scope TEXT NOT NULL CHECK(scope IN ('account','customer','fingerprint')),
 scope_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','consumed','released')),
 session_id TEXT, subscription_id TEXT, account_id TEXT, customer_id TEXT,
 reserved_at TEXT NOT NULL, consumed_at TEXT, updated_at TEXT NOT NULL,
 PRIMARY KEY(scope, scope_id)
);
CREATE TABLE IF NOT EXISTS stripe_customer_bindings (
 customer_id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS stripe_trial_conflicts (
 id TEXT PRIMARY KEY, conflict_kind TEXT NOT NULL, scope TEXT NOT NULL,
 scope_id TEXT NOT NULL, account_id TEXT, customer_id TEXT,
 subscription_id TEXT, detail TEXT NOT NULL, created_at TEXT NOT NULL,
 UNIQUE(conflict_kind,scope,scope_id,account_id,customer_id,subscription_id)
);
COMMIT;
