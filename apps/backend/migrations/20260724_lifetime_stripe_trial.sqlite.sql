-- SQLite forward migration/backfill for one lifetime Stripe trial.
-- The application also performs these additive operations idempotently at
-- startup for the currently deployed SQLite runtime.
ALTER TABLE users ADD COLUMN stripe_trial_reserved_at TEXT;
ALTER TABLE accounts ADD COLUMN stripe_trial_reserved_at TEXT;

UPDATE users
SET stripe_trial_reserved_at = COALESCE(created_at, CURRENT_TIMESTAMP)
WHERE stripe_trial_reserved_at IS NULL
  AND (stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL);

UPDATE accounts
SET stripe_trial_reserved_at = COALESCE(created_at, CURRENT_TIMESTAMP)
WHERE stripe_trial_reserved_at IS NULL
  AND (stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL);
