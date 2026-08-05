-- SQLite forward migration: RevenueCat re-query reconciliation annotation.
-- Additive only — adds one nullable column; no row is deleted or rewritten, so
-- the append-only shadow ledger is preserved. The live SQLite application ALSO
-- applies this idempotently at startup (store.py: the ALTER is suppressed if the
-- column already exists), so this script is the operator-run mirror.
--
-- Purpose: a shadow observation is point-in-time. An INITIAL_PURCHASE that later
-- expired stays on the ledger as a flip-eligible disagreement even though
-- RevenueCat's CURRENT truth now agrees with the free legacy projection, pinning
-- shadow_clean false. `reconciled_at` records that a later re-query of RC's
-- current access confirmed the disagreement is stale; the flip summary then
-- counts that row as an agreement. A REAL standing disagreement (RC still active)
-- is never reconciled, so it keeps blocking the cutover.
BEGIN IMMEDIATE;
ALTER TABLE revenuecat_shadow_observations ADD COLUMN reconciled_at TEXT;
COMMIT;
