-- PostgreSQL forward migration: RevenueCat re-query reconciliation annotation.
-- Additive only; the runtime SQLite application is authoritative today, this is
-- the Postgres mirror. Adds one nullable column; no row is deleted or rewritten.
--
-- Purpose: `reconciled_at` records that a later re-query of RevenueCat's CURRENT
-- access confirmed a historical flip-eligible disagreement is stale (RC no longer
-- supports it — its current access now agrees with the legacy projection), so the
-- flip summary counts that row as an agreement instead of blocking the cutover.
-- A real standing disagreement (RC still active) is never reconciled.
BEGIN;
ALTER TABLE revenuecat_shadow_observations ADD COLUMN IF NOT EXISTS reconciled_at TEXT;
COMMIT;
