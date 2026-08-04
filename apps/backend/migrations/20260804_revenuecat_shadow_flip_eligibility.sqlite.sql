-- SQLite forward migration: RevenueCat shadow-canary flip-eligibility (build 126
-- corrective). Additive: adds one nullable column and backfills it from durable
-- event evidence. No row is deleted or rewritten; the append-only shadow ledger
-- is preserved. The live SQLite application ALSO applies this idempotently at
-- startup (store.py: the ALTER is suppressed if the column already exists, and
-- _backfill_revenuecat_shadow_store_source recovers the store from the durable
-- revenuecat_events payload), so this script is the operator-run mirror.
--
-- Root cause it fixes: the flip gate counted a RevenueCat PROMOTIONAL admin
-- grant as a shadow disagreement. A promotional grant makes RevenueCat active
-- with NO underlying store purchase, so in shadow mode it legitimately disagrees
-- with the (correct) free legacy projection, permanently pinning shadow_clean
-- false even on a healthy integration. store_source lets the flip decision be
-- computed from real store-parity canaries only.
--
-- Note: SQLite has no ADD COLUMN IF NOT EXISTS. Re-running after the column
-- exists raises "duplicate column name" harmlessly; skip the ALTER in that case.
BEGIN IMMEDIATE;

ALTER TABLE revenuecat_shadow_observations ADD COLUMN store_source TEXT;

-- Backfill existing rows from the durable revenuecat_events row each observation
-- was derived from (both tables key on event_id): the already-extracted
-- store_source column first, then the raw payload JSON as a fallback (the same
-- body RevenueCat delivered), mirroring the runtime
-- _backfill_revenuecat_shadow_store_source. Only NULL rows are touched and only
-- where a store can be recovered, so this is deterministic and idempotent.
UPDATE revenuecat_shadow_observations
   SET store_source = (
         SELECT COALESCE(e.store_source, json_extract(e.payload, '$.event.store'))
           FROM revenuecat_events e
          WHERE e.event_id = revenuecat_shadow_observations.event_id
       )
 WHERE store_source IS NULL
   AND EXISTS (
         SELECT 1 FROM revenuecat_events e2
          WHERE e2.event_id = revenuecat_shadow_observations.event_id
            AND COALESCE(e2.store_source, json_extract(e2.payload, '$.event.store')) IS NOT NULL
       );

COMMIT;
