-- PostgreSQL forward migration. Unique constraints, not process-local locks,
-- arbitrate reservations and customer ownership.
BEGIN;
CREATE TABLE IF NOT EXISTS stripe_trial_ledger (
 scope TEXT NOT NULL CHECK(scope IN ('account','customer','fingerprint')),
 scope_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('reserved','consumed','released')),
 session_id TEXT, subscription_id TEXT, account_id UUID, customer_id TEXT,
 reserved_at TIMESTAMPTZ NOT NULL, consumed_at TIMESTAMPTZ,
 updated_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY(scope, scope_id)
);
CREATE TABLE IF NOT EXISTS stripe_customer_bindings (
 customer_id TEXT PRIMARY KEY,
 account_id UUID NOT NULL UNIQUE REFERENCES accounts(id),
 created_at TIMESTAMPTZ NOT NULL, updated_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS stripe_trial_conflicts (
 id TEXT PRIMARY KEY, conflict_kind TEXT NOT NULL, scope TEXT NOT NULL,
 scope_id TEXT NOT NULL, account_id UUID, customer_id TEXT,
 subscription_id TEXT, detail TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL,
 UNIQUE NULLS NOT DISTINCT
   (conflict_kind,scope,scope_id,account_id,customer_id,subscription_id)
);

INSERT INTO stripe_trial_ledger
 (scope,scope_id,state,account_id,customer_id,reserved_at,consumed_at,updated_at)
SELECT 'account', id::text, 'consumed', id, stripe_customer_id,
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM accounts
 WHERE stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL
    OR subscription_status IS NOT NULL
ON CONFLICT(scope,scope_id) DO NOTHING;
INSERT INTO stripe_trial_ledger
 (scope,scope_id,state,account_id,customer_id,reserved_at,consumed_at,updated_at)
SELECT 'account', account_id::text, 'consumed', account_id, stripe_customer_id,
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM users
 WHERE account_id IS NOT NULL AND
       (stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL
        OR subscription_status IS NOT NULL)
ON CONFLICT(scope,scope_id) DO NOTHING;
INSERT INTO stripe_trial_ledger
 (scope,scope_id,state,account_id,reserved_at,consumed_at,updated_at)
SELECT 'account', app_account_token::text, 'consumed', app_account_token,
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM provider_purchases
 WHERE provider='stripe' AND app_account_token IS NOT NULL
ON CONFLICT(scope,scope_id) DO NOTHING;
INSERT INTO stripe_trial_ledger
 (scope,scope_id,state,account_id,customer_id,reserved_at,consumed_at,updated_at)
SELECT 'customer', stripe_customer_id, 'consumed', id, stripe_customer_id,
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM accounts WHERE stripe_customer_id IS NOT NULL
ON CONFLICT(scope,scope_id) DO NOTHING;

INSERT INTO stripe_customer_bindings(customer_id,account_id,created_at,updated_at)
SELECT DISTINCT ON (stripe_customer_id) stripe_customer_id,id,
       CURRENT_TIMESTAMP,CURRENT_TIMESTAMP
  FROM accounts WHERE stripe_customer_id IS NOT NULL
 ORDER BY stripe_customer_id,created_at,id
ON CONFLICT DO NOTHING;
INSERT INTO stripe_trial_conflicts
 (id,conflict_kind,scope,scope_id,detail,created_at)
SELECT md5('legacy_customer_duplicate:' || stripe_customer_id),
       'legacy_customer_duplicate','customer',stripe_customer_id,
       'multiple legacy accounts referenced this customer; canonical binding retained',
       CURRENT_TIMESTAMP
  FROM accounts WHERE stripe_customer_id IS NOT NULL
 GROUP BY stripe_customer_id HAVING COUNT(*) > 1
ON CONFLICT DO NOTHING;
COMMIT;
