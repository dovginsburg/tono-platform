-- PostgreSQL forward migration: RevenueCat canary seam (build 123).
-- Additive only; the runtime SQLite application is authoritative today, this is
-- the Postgres mirror for a future cutover. The application writes ISO-8601 UTC
-- text for timestamps and integer millis for event_ms, so text/bigint columns
-- match the writer exactly. RevenueCat reuses the shared provider_purchases
-- (provider='revenuecat') + entitlement_grants tables — unchanged here.
BEGIN;

CREATE TABLE IF NOT EXISTS revenuecat_events (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id      TEXT NOT NULL,
    event_type    TEXT NOT NULL,
    app_user_id   TEXT,
    store_source  TEXT,
    environment   TEXT,
    event_ms      BIGINT NOT NULL DEFAULT 0,
    payload       TEXT NOT NULL,
    state         TEXT NOT NULL CHECK (state IN ('received','processed','failed','dead_letter')),
    outcome       TEXT,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    received_at   TEXT NOT NULL,
    processed_at  TEXT,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_events_state ON revenuecat_events(state);

CREATE TABLE IF NOT EXISTS revenuecat_shadow_observations (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id          TEXT NOT NULL,
    account_id        TEXT,
    revenuecat_active INTEGER NOT NULL,
    legacy_active     INTEGER NOT NULL,
    agree             INTEGER NOT NULL,
    mode              TEXT NOT NULL CHECK (mode IN ('shadow','authoritative')),
    detail            TEXT,
    created_at        TEXT NOT NULL,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_shadow_agree ON revenuecat_shadow_observations(agree);

COMMIT;
