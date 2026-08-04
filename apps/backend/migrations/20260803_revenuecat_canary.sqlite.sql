-- SQLite forward migration: RevenueCat canary seam (build 123).
-- Additive only. The live SQLite application ALSO creates these idempotently at
-- startup (store.py SCHEMA), so this script is the operator-run mirror. Safe to
-- run while traffic is live: CREATE TABLE IF NOT EXISTS never touches existing
-- rows and no other table is modified. RevenueCat itself reuses the shared
-- provider_purchases (provider='revenuecat') + entitlement_grants tables — no
-- change to those is needed (provider has no CHECK constraint).
BEGIN IMMEDIATE;

-- Durable, product-specific webhook inbox keyed by the RevenueCat event id.
CREATE TABLE IF NOT EXISTS revenuecat_events (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id      TEXT NOT NULL,
    event_type    TEXT NOT NULL,
    app_user_id   TEXT,
    store_source  TEXT,
    environment   TEXT,
    event_ms      INTEGER NOT NULL DEFAULT 0,
    payload       TEXT NOT NULL,
    state         TEXT NOT NULL,          -- 'received'|'processed'|'failed'|'dead_letter'
    outcome       TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    received_at   TEXT NOT NULL,
    processed_at  TEXT,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_events_state ON revenuecat_events(state);

-- Canary shadow ledger: RevenueCat-derived entitlement vs the legacy projection.
CREATE TABLE IF NOT EXISTS revenuecat_shadow_observations (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id          TEXT NOT NULL,
    account_id        TEXT,
    revenuecat_active INTEGER NOT NULL,
    legacy_active     INTEGER NOT NULL,
    agree             INTEGER NOT NULL,
    mode              TEXT NOT NULL,       -- 'shadow'|'authoritative'
    detail            TEXT,
    created_at        TEXT NOT NULL,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_shadow_agree ON revenuecat_shadow_observations(agree);

COMMIT;
