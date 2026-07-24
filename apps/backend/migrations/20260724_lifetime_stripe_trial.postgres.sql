-- PostgreSQL-compatible forward migration/backfill for the future Store port.
-- Run in one transaction before serving checkout traffic.
BEGIN;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS stripe_trial_reserved_at TIMESTAMPTZ;
ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS stripe_trial_reserved_at TIMESTAMPTZ;

UPDATE users
SET stripe_trial_reserved_at = COALESCE(created_at, CURRENT_TIMESTAMP)
WHERE stripe_trial_reserved_at IS NULL
  AND (stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL);

UPDATE accounts
SET stripe_trial_reserved_at = COALESCE(created_at, CURRENT_TIMESTAMP)
WHERE stripe_trial_reserved_at IS NULL
  AND (stripe_customer_id IS NOT NULL OR stripe_subscription_id IS NOT NULL);

COMMIT;
