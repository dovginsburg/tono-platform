-- PostgreSQL forward migration: RevenueCat shadow-canary flip-eligibility (build
-- 126 corrective). Additive only; the runtime SQLite application is authoritative
-- today, this is the Postgres mirror for a future cutover. Adds one nullable
-- column and backfills it from durable event evidence — no row is deleted or
-- rewritten, so the append-only shadow ledger (including promotional
-- observations) is preserved.
--
-- Root cause it fixes: the flip gate counted a RevenueCat PROMOTIONAL admin grant
-- as a shadow disagreement. A promotional grant makes RevenueCat active with no
-- underlying store purchase, so in shadow mode it legitimately disagrees with the
-- (correct) free legacy projection, permanently pinning shadow_clean false even
-- on a healthy integration. store_source lets the flip decision be computed from
-- real store-parity canaries (App Store/Play/Stripe/RC Billing/Test Store/...)
-- only, while PROMOTIONAL rows stay in lifetime diagnostics.
BEGIN;

ALTER TABLE revenuecat_shadow_observations ADD COLUMN IF NOT EXISTS store_source TEXT;

-- Backfill existing rows from the durable revenuecat_events row each observation
-- was derived from (both key on event_id): the already-extracted store_source
-- column first, then the raw payload JSON as a fallback (the same body RevenueCat
-- delivered). Only NULL rows are touched, so this is deterministic and idempotent.
UPDATE revenuecat_shadow_observations o
   SET store_source = COALESCE(e.store_source, e.payload::jsonb -> 'event' ->> 'store')
  FROM revenuecat_events e
 WHERE e.event_id = o.event_id
   AND o.store_source IS NULL
   AND COALESCE(e.store_source, e.payload::jsonb -> 'event' ->> 'store') IS NOT NULL;

COMMIT;
