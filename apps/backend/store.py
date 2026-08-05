"""SQLite-backed user + usage store for the Tono backend.

Single source of truth for:
  - devices (one row per install; identity = `device_id` issued by the iOS app)
  - bearer tokens (long random; opaque; rotated on demand)
  - daily rewrite counter (resets at UTC midnight)
  - Stripe customer + subscription linkage
  - plan tier ("free" | "pro")
  - response cache (SHA-256 keyed, 5-min TTL)
  - axis events (which rewrite axis users tap)
  - Slack workspace installs

Why SQLite: Tono's traffic profile is < 50K devices at MVP scale. SQLite
+ WAL + a single FastAPI worker on Railway/Fly handles that for free.
We move to Postgres only when single-writer becomes a bottleneck.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import json
import os
import secrets
import sqlite3
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Iterator, Optional

from . import email_identity


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    device_id            TEXT PRIMARY KEY,
    api_token            TEXT NOT NULL UNIQUE,
    device_credential_hash TEXT,
    previous_api_token     TEXT,
    previous_api_token_expires_at TEXT,
    plan                 TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id   TEXT,
    stripe_subscription_id TEXT,
    subscription_status  TEXT,
    subscription_renews_at TEXT,
    daily_count          INTEGER NOT NULL DEFAULT 0,
    daily_day            TEXT,
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_token ON users(api_token);
CREATE INDEX IF NOT EXISTS idx_users_stripe_customer ON users(stripe_customer_id);

-- A device (row in `users` above) is anonymous by default. Signing in with
-- Apple/Google upserts a row here and sets `users.account_id`, so Pro status
-- and identity travel with the person rather than the install. Plan/
-- subscription fields are duplicated from `users` deliberately: once an
-- account exists it is the source of truth for billing, and `users` keeps
-- its own copy only for the anonymous (never-signed-in) case.
CREATE TABLE IF NOT EXISTS accounts (
    id                      TEXT PRIMARY KEY,
    apple_sub               TEXT UNIQUE,
    google_sub              TEXT UNIQUE,
    -- Supabase user id (the web sign-in provider subject). Stable per person
    -- across browsers and OAuth providers, so two browsers signing into the
    -- same Supabase user converge onto this one account. UNIQUE so a subject
    -- can never silently belong to two accounts.
    supabase_sub            TEXT,
    -- Set to the account's own id when the account is deleted: the row is
    -- kept (tombstoned) so append-only billing/provider audit facts that
    -- reference it stay valid, but all identity/private columns are cleared.
    deleted_at              TEXT,
    email                   TEXT,
    plan                    TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id      TEXT,
    stripe_subscription_id  TEXT,
    subscription_status     TEXT,
    subscription_renews_at  TEXT,
    coupon_pro_expires_at   TEXT,
    -- Non-authorizing daily rewrite telemetry counter, pooled across every
    -- device linked to this account — see record_rewrite (there is NO free
    -- daily tier; this counter never grants access). Same shape as
    -- users.daily_count/daily_day, deliberately: a device with no account_id
    -- still counts against ITS OWN columns of the same name on `users`.
    daily_count             INTEGER NOT NULL DEFAULT 0,
    daily_day               TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_accounts_apple_sub ON accounts(apple_sub);
CREATE INDEX IF NOT EXISTS idx_accounts_google_sub ON accounts(google_sub);
CREATE INDEX IF NOT EXISTS idx_accounts_stripe_customer ON accounts(stripe_customer_id);

-- Monotonic one-lifetime-trial authority.  The primary key is the concurrency
-- arbiter on SQLite and maps directly to PostgreSQL ON CONFLICT semantics.
CREATE TABLE IF NOT EXISTS stripe_trial_ledger (
    scope             TEXT NOT NULL CHECK(scope IN ('account','customer','fingerprint')),
    scope_id          TEXT NOT NULL,
    state             TEXT NOT NULL CHECK(state IN ('reserved','consumed','released')),
    session_id        TEXT,
    subscription_id   TEXT,
    account_id        TEXT,
    customer_id       TEXT,
    reserved_at       TEXT NOT NULL,
    consumed_at       TEXT,
    updated_at        TEXT NOT NULL,
    PRIMARY KEY (scope, scope_id)
);
CREATE INDEX IF NOT EXISTS idx_trial_ledger_session ON stripe_trial_ledger(session_id);
CREATE INDEX IF NOT EXISTS idx_trial_ledger_subscription ON stripe_trial_ledger(subscription_id);

-- Canonical Stripe customer ownership. Both columns are unique, preventing a
-- customer from moving between accounts and an account from acquiring two
-- reachable customers under concurrent checkout.
CREATE TABLE IF NOT EXISTS stripe_customer_bindings (
    customer_id TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL UNIQUE REFERENCES accounts(id),
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS stripe_trial_conflicts (
    id              TEXT PRIMARY KEY,
    conflict_kind   TEXT NOT NULL,
    scope           TEXT NOT NULL,
    scope_id        TEXT NOT NULL,
    account_id      TEXT,
    customer_id     TEXT,
    subscription_id TEXT,
    detail          TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    UNIQUE(conflict_kind, scope, scope_id, account_id, customer_id, subscription_id)
);

-- A passkey (WebAuthn credential) is what makes Face ID / Touch ID /
-- Windows Hello / Android biometric unlock work as a *login* method on
-- web and desktop: the browser/OS handles the biometric prompt and only
-- ever gives us back a signed assertion, never the biometric itself.
-- credential_id is base64url-encoded (WebAuthn's own encoding), so it's
-- TEXT despite being derived from bytes.
CREATE TABLE IF NOT EXISTS webauthn_credentials (
    credential_id   TEXT PRIMARY KEY,
    account_id      TEXT NOT NULL REFERENCES accounts(id),
    public_key      BLOB NOT NULL,
    sign_count      INTEGER NOT NULL DEFAULT 0,
    transports      TEXT,
    nickname        TEXT,
    created_at      TEXT NOT NULL,
    last_used_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_webauthn_account ON webauthn_credentials(account_id);

-- Build 114: the product-owned registration record for an email account.
-- Supabase owns auth.users (passwords, verification links, reset links); this
-- table owns the PRODUCT fact — which canonical account the identity belongs
-- to, what lifecycle state it is in, and when/where that changed. It holds no
-- password material, no auth token, and no provider payload.
--
-- account_id is the primary key, NOT the email: the canonical principal is the
-- immutable account UUID and the email is a login/recovery identity hanging
-- off it. Making the email the key is exactly the mistake that turns "two
-- people, one shared address spelling" into a silent account merge.
CREATE TABLE IF NOT EXISTS account_registrations (
    account_id       TEXT PRIMARY KEY REFERENCES accounts(id),
    lifecycle_state  TEXT NOT NULL CHECK(lifecycle_state IN ('pending','verified','disabled')),
    -- Normalized comparison form (see email_identity.normalize_email). NULL
    -- while an identity has no email at all (e.g. an Apple sign-in that
    -- returned none).
    email_normalized TEXT,
    provider         TEXT NOT NULL,
    created_at       TEXT NOT NULL,
    verified_at      TEXT,
    -- Where the registration was STARTED. Immutable once known — see
    -- `_upsert_registration_row`. A later sign-in from another surface moves
    -- `last_seen_surface`, never this.
    source_surface   TEXT NOT NULL DEFAULT 'unknown',
    -- The build the registration was started from. First non-null wins, for
    -- the same reason.
    app_build        TEXT,
    -- The most recent ATTESTED surface/build. "Attested" means a caller that
    -- proved which account it was acting for (a device bearer, or a
    -- provider-verified token) — never an unauthenticated address-scoped
    -- request, which cannot be trusted to describe someone else's account.
    last_seen_surface TEXT,
    last_seen_app_build TEXT,
    last_sign_in_at  TEXT,
    last_seen_at     TEXT,
    updated_at       TEXT NOT NULL,
    -- The auth provider's own subject for the user this registration created,
    -- recorded BEFORE verification. This is what makes the anonymous upgrade
    -- actually hold: whichever surface completes the verification resolves
    -- this claim and lands on THIS canonical account rather than minting a
    -- second one (see `claim_pending_registration_account`). An opaque public
    -- identifier, not a credential — it grants nothing on its own, and the
    -- account stays unidentified until an address is proven.
    provider_subject TEXT
);
-- A provider subject backs exactly ONE canonical registration. Partial so the
-- overwhelmingly common NULL case is unconstrained.
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_registrations_provider_subject
    ON account_registrations(provider_subject)
    WHERE provider_subject IS NOT NULL;
-- A verified address may back exactly ONE canonical account. Partial index so
-- pending rows (which have not proved ownership yet) can legitimately race for
-- the same address, and only the one that verifies claims it. A second
-- verification for the same address raises rather than merging.
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_registrations_verified_email
    ON account_registrations(email_normalized)
    WHERE lifecycle_state = 'verified' AND email_normalized IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_account_registrations_state
    ON account_registrations(lifecycle_state);

-- Append-only lifecycle audit. Deliberately carries NO email column: the
-- address lives once, on the registration row above, and an event stream is
-- the last place a raw identifier should be duplicated. `detail` is a short
-- server-chosen code, never a client string, provider response, or payload.
CREATE TABLE IF NOT EXISTS account_registration_events (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id     TEXT,
    event_type     TEXT NOT NULL,
    occurred_at    TEXT NOT NULL,
    source_surface TEXT NOT NULL DEFAULT 'unknown',
    app_build      TEXT,
    detail         TEXT
);
CREATE INDEX IF NOT EXISTS idx_registration_events_account
    ON account_registration_events(account_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_registration_events_ts
    ON account_registration_events(occurred_at);

CREATE TABLE IF NOT EXISTS usage_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id     TEXT NOT NULL,
    ts            TEXT NOT NULL,
    endpoint      TEXT NOT NULL,
    status_code   INTEGER NOT NULL,
    provider      TEXT,
    drafts_chars  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_usage_device_ts ON usage_log(device_id, ts);

CREATE TABLE IF NOT EXISTS stripe_events (
    event_id      TEXT PRIMARY KEY,
    received_at   TEXT NOT NULL,
    type          TEXT NOT NULL,
    payload       TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS response_cache (
    cache_key     TEXT PRIMARY KEY,
    response_json TEXT NOT NULL,
    created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS axis_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id  TEXT NOT NULL,
    ts         TEXT NOT NULL,
    axis       TEXT NOT NULL,
    risk_level TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_axis_ts ON axis_events(ts);

CREATE TABLE IF NOT EXISTS improvement_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id       TEXT NOT NULL,
    ts              TEXT NOT NULL,
    risk_predicted  TEXT NOT NULL,
    axis_selected   TEXT,
    mode            TEXT NOT NULL DEFAULT 'coach',
    msg_len_bucket  TEXT NOT NULL DEFAULT 'medium',
    rewrite_used    INTEGER NOT NULL DEFAULT 0,
    edit_after      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_improvement_ts ON improvement_events(ts);
CREATE INDEX IF NOT EXISTS idx_improvement_device ON improvement_events(device_id);

CREATE TABLE IF NOT EXISTS slack_workspaces (
    team_id       TEXT PRIMARY KEY,
    access_token  TEXT NOT NULL,
    team_name     TEXT,
    bot_user_id   TEXT,
    installed_at  TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS coupons (
    code           TEXT PRIMARY KEY,
    duration_days  INTEGER NOT NULL,
    max_uses       INTEGER NOT NULL DEFAULT 0,
    use_count      INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL,
    expires_at     TEXT,
    -- App-review compatibility (Build 117). A coupon with anonymous_eligible=1
    -- may be redeemed by an UNIDENTIFIED canonical account (a reviewer who
    -- skipped onboarding and cannot sign in). DEFAULT 0 keeps every existing
    -- and future coupon identity-gated — this is an opt-in, per-coupon bypass,
    -- never a universal anonymous promo. Bound its blast radius at creation
    -- with a small max_uses and a near expires_at.
    anonymous_eligible INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS coupon_redemptions (
    device_id     TEXT NOT NULL,
    code          TEXT NOT NULL,
    redeemed_at   TEXT NOT NULL,
    PRIMARY KEY (device_id, code)
);

-- Build 120: coupon authority follows the immutable canonical account.  The
-- legacy device ledger above remains untouched for audit/rollback only.
CREATE TABLE IF NOT EXISTS account_coupon_redemptions (
    account_id    TEXT NOT NULL REFERENCES accounts(id),
    code          TEXT NOT NULL REFERENCES coupons(code),
    redeemed_at   TEXT NOT NULL,
    expires_at    TEXT NOT NULL,
    PRIMARY KEY (account_id, code)
);
CREATE INDEX IF NOT EXISTS idx_account_coupon_code
    ON account_coupon_redemptions(code);

CREATE TABLE IF NOT EXISTS feature_flags (
    key             TEXT PRIMARY KEY,
    enabled         INTEGER NOT NULL DEFAULT 1,
    plan_required   TEXT,
    rollout_pct     INTEGER NOT NULL DEFAULT 100,
    user_controllable INTEGER NOT NULL DEFAULT 0,
    description     TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS user_feature_overrides (
    device_id   TEXT NOT NULL,
    flag_key    TEXT NOT NULL,
    enabled     INTEGER NOT NULL,
    set_by      TEXT NOT NULL DEFAULT 'user',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (device_id, flag_key)
);

-- ── Build-91 mobile (Apple) entitlement seam ───────────────────────────────
-- Minimum durable model that keeps three concepts from collapsing into one:
--   * who OWNS the store purchase        -> provider_purchases
--   * who is ENTITLED to paid service    -> entitlement_grants (per beneficiary)
--   * who first CLAIMED a tokenless lineage -> legacy_claims (uniqueness wins)
-- This is deliberately NOT a general append-only event ledger/materializer;
-- it is the smallest schema that makes purchase, entitlement, and account
-- recovery independently addressable (see build-91 contract §2).

-- One row per store purchase lineage (keyed by original transaction).
-- `lifecycle_state` is the durable current-provider truth, kept current by
-- verified App Store Server Notifications V2 plus purchase/restore sync, so a
-- replayed older signed transaction can never resurrect a refunded/revoked
-- purchase (contract §3). `latest_signed_ms` is the newest provider timestamp
-- we've accepted; older signed evidence is ignored (timestamp guard).
CREATE TABLE IF NOT EXISTS provider_purchases (
    id                      TEXT PRIMARY KEY,
    provider                TEXT NOT NULL,
    original_transaction_id TEXT NOT NULL,
    latest_transaction_id   TEXT,
    product_id              TEXT NOT NULL,
    environment             TEXT NOT NULL,
    ownership_type          TEXT NOT NULL,     -- 'PURCHASED' | 'FAMILY_SHARED'
    app_account_token       TEXT,              -- canonical account UUID, or NULL (legacy/family)
    lifecycle_state         TEXT NOT NULL,     -- 'active'|'expired'|'refunded'|'revoked'
    latest_signed_ms        INTEGER NOT NULL DEFAULT 0,
    expires_ms              INTEGER,
    trial_consumed          INTEGER NOT NULL DEFAULT 0,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    UNIQUE(provider, original_transaction_id)
);

-- Durable inbox for verified provider events (transaction ids + notification
-- UUIDs). The UNIQUE key is the replay-safety primitive for crash-recovery and
-- duplicate/out-of-order notification delivery (contract §9, hostile 11/16).
CREATE TABLE IF NOT EXISTS provider_transactions (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    provider      TEXT NOT NULL,
    event_id      TEXT NOT NULL,               -- transactionId or notificationUUID
    kind          TEXT NOT NULL,               -- 'transaction' | 'notification'
    outcome       TEXT NOT NULL,
    received_at   TEXT NOT NULL,
    UNIQUE(provider, event_id)
);

-- Revocable entitlement to paid service for one beneficiary account. A direct
-- purchase grants the purchaser; a FAMILY_SHARED purchase grants the family
-- beneficiary without transferring ownership (contract §4/§6). At most one
-- grant row per (purchase, beneficiary).
CREATE TABLE IF NOT EXISTS entitlement_grants (
    id            TEXT PRIMARY KEY,
    purchase_id   TEXT NOT NULL REFERENCES provider_purchases(id),
    account_id    TEXT NOT NULL REFERENCES accounts(id),
    grant_kind    TEXT NOT NULL,               -- 'direct' | 'family'
    state         TEXT NOT NULL,               -- 'active' | 'revoked'
    effective_at  TEXT NOT NULL,
    expires_at    TEXT,
    revoked_at    TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL,
    UNIQUE(purchase_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_grants_account ON entitlement_grants(account_id);

-- Immutable first-claim evidence for a tokenless (build-90/stale-client)
-- direct purchase. The UNIQUE lineage key — not timing or app memory — selects
-- the single first claimant; later different-account claims conflict, identical
-- retries by the winner are idempotent (contract §5, hostile 10).
CREATE TABLE IF NOT EXISTS legacy_claims (
    id                      TEXT PRIMARY KEY,
    provider                TEXT NOT NULL,
    original_transaction_id TEXT NOT NULL,
    claimant_account_id     TEXT NOT NULL REFERENCES accounts(id),
    evidence_key            TEXT NOT NULL,      -- transaction id used as claim evidence
    result                  TEXT NOT NULL,      -- 'granted'
    claimed_at              TEXT NOT NULL,
    UNIQUE(provider, original_transaction_id)
);

-- Durable record + retry state for outbound mutable provider actions (Set App
-- Account Token after a tokenless claim). A transient failure never erases an
-- already provider-verified paid entitlement; the op is retried (contract §5/§9,
-- hostile 12). One op per lineage.
CREATE TABLE IF NOT EXISTS provider_operations (
    id                      TEXT PRIMARY KEY,
    provider                TEXT NOT NULL,
    op_kind                 TEXT NOT NULL,      -- 'set_app_account_token'
    original_transaction_id TEXT NOT NULL,
    account_id              TEXT NOT NULL,
    state                   TEXT NOT NULL,      -- 'pending'|'succeeded'|'failed'
    attempts                INTEGER NOT NULL DEFAULT 0,
    last_error              TEXT,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    UNIQUE(provider, op_kind, original_transaction_id)
);

-- Non-destructive record of a verified provider event we could not safely
-- apply because the target beneficiary can't be proven — e.g. a tokenless
-- FAMILY_SHARED revoke, which must NOT mass-revoke every beneficiary. The event
-- is durably parked here for provider reconciliation instead of guessing who to
-- revoke (contract §6, P0 tokenless family revoke). Deduped by notificationUUID.
CREATE TABLE IF NOT EXISTS provider_unresolved_events (
    id                      TEXT PRIMARY KEY,
    provider                TEXT NOT NULL,
    notification_uuid       TEXT NOT NULL,
    notification_type       TEXT NOT NULL,
    original_transaction_id TEXT NOT NULL,
    reason                  TEXT NOT NULL,
    created_at              TEXT NOT NULL,
    UNIQUE(provider, notification_uuid)
);

-- ── RevenueCat canary seam ──────────────────────────────────────────────────
-- RevenueCat is the first Tono canary for a unified subscription lifecycle. It
-- is an isolated per-product project whose events flow into the SAME provider
-- fact + entitlement projection every other provider uses (provider_purchases
-- provider='revenuecat' -> entitlement_grants), so there stays exactly ONE
-- deterministic entitlement writer. These two tables are RevenueCat-specific.

-- Durable, product-specific webhook inbox keyed by the RevenueCat event id (the
-- provider's own idempotency key). Richer than the generic provider_transactions
-- inbox: it stores the raw payload for async re-processing + reconciliation and a
-- per-event state machine with retry attempts and a dead-letter terminal state
-- (contract §5). UNIQUE(event_id) is the replay-safety primitive — a duplicate
-- delivery is detected here and never re-projected.
CREATE TABLE IF NOT EXISTS revenuecat_events (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id      TEXT NOT NULL,                 -- RevenueCat event.id (idempotency key)
    event_type    TEXT NOT NULL,                 -- INITIAL_PURCHASE|RENEWAL|CANCELLATION|EXPIRATION|...
    app_user_id   TEXT,                          -- RevenueCat app_user_id == canonical account UUID (or NULL)
    store_source  TEXT,                          -- APP_STORE|PLAY_STORE|STRIPE|... (RevenueCat 'store')
    environment   TEXT,                          -- SANDBOX|PRODUCTION
    event_ms      INTEGER NOT NULL DEFAULT 0,    -- event_timestamp_ms (monotonic version oracle)
    payload       TEXT NOT NULL,                 -- raw event JSON (async reprocess / reconcile)
    state         TEXT NOT NULL,                 -- 'received'|'processed'|'failed'|'dead_letter'
    outcome       TEXT,                          -- terminal projection outcome label
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    received_at   TEXT NOT NULL,
    processed_at  TEXT,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_events_state ON revenuecat_events(state);

-- Canary shadow ledger: for each RevenueCat event we record the RevenueCat-
-- derived entitlement decision and the legacy projection at that instant, so a
-- reconciler surfaces disagreements WITHOUT RevenueCat being the authority in
-- 'shadow' mode. Append-only, deduped by event_id (contract §6/§9).
--
-- `store_source` (the RevenueCat 'store') is the flip-eligibility class key: a
-- PROMOTIONAL admin grant makes RevenueCat active with NO underlying store
-- purchase, so in shadow mode it legitimately disagrees with the (correct) free
-- legacy projection. Promotional observations are retained here for lifetime
-- diagnostics but EXCLUDED from the shadow->authoritative flip decision; every
-- real customer store (App Store/Play/Stripe/...) stays a flip-eligible
-- store-parity canary. Rows written before build 126 have store_source NULL and
-- are backfilled from the durable revenuecat_events payload on startup.
CREATE TABLE IF NOT EXISTS revenuecat_shadow_observations (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id          TEXT NOT NULL,
    account_id        TEXT,
    store_source      TEXT,                      -- RevenueCat 'store': APP_STORE|PLAY_STORE|STRIPE|PROMOTIONAL|... (flip-eligibility class)
    revenuecat_active INTEGER NOT NULL,          -- RevenueCat-derived entitled? (0/1)
    legacy_active     INTEGER NOT NULL,          -- legacy is_pro at observation time (0/1)
    agree             INTEGER NOT NULL,          -- revenuecat_active == legacy_active (0/1)
    mode              TEXT NOT NULL,             -- 'shadow'|'authoritative'
    detail            TEXT,
    created_at        TEXT NOT NULL,
    UNIQUE(event_id)
);
CREATE INDEX IF NOT EXISTS idx_revenuecat_shadow_agree ON revenuecat_shadow_observations(agree);
"""

_DEFAULT_FLAGS = [
    # (key, enabled, plan_required, rollout_pct, user_controllable, description)
    ("onboarding_calibration", 1, None, 100, 0, "First-run 3-question calibration flow"),
    ("thread_context",         1, None, 100, 1, "Paste prior message for context-aware rewrites"),
    ("weekly_digest",          1, None, 100, 1, "Weekly tone summary notification and report"),
    ("custom_axes",            1, "pro", 100, 0, "User-defined rewrite dimensions (Pro only)"),
    ("risk_delta",             1, None, 100, 1, "Show predicted risk change per rewrite suggestion"),
    ("memory_inference",       1, None, 100, 1, "Auto-infer facts from usage patterns (privacy)"),
    ("memory_context_hints",   1, None, 100, 1, "Send memory facts as LLM context hints (privacy)"),
    # Collective improvement signal — content-free behavioral outcomes only.
    # k-anonymity floor (COLLECTIVE_MIN_DEVICES) enforced at aggregation query level.
    ("improve_tono",           1, None, 100, 1, "Share anonymous outcome signals to improve Tono for everyone"),
    # Build 115 — the on-device Apple Intelligence rewrite route's kill switch.
    #
    # `get_features` returns exactly the rows in this table, so a key that was
    # never seeded can never appear in a `/v1/features` response. The iOS client
    # resolves the cached value or its own default, and that default is ON —
    # which meant the "remote kill switch" documented in `FeatureFlags.swift`
    # had no way to say OFF: the only way to disable the route in the field was
    # a new build. Seeded ENABLED, so the resolved value is exactly what it
    # already was and no behaviour changes. What changes is that
    # `PATCH /admin/flags/apple_intelligence_rewrite_enabled` with enabled false
    # now matches a row, and takes effect on every device's next feature fetch.
    #
    # NOT user-controllable: it is an operator switch, and the person's own
    # opt-out deliberately lives elsewhere (iOS `LocalRewritePreferenceStore`,
    # its own App Group key), because `FeatureFlags.update(from:)` replaces this
    # whole dictionary on every fetch and would evaporate a preference stored
    # here. `plan_required` is None — the route is not a Pro feature.
    ("apple_intelligence_rewrite_enabled", 1, None, 100, 0,
     "Master switch for the on-device Apple Intelligence rewrite route (operator kill switch)"),
]


# Terminal (not-entitled) provider lifecycle states. A purchase in any of these
# never grants Pro, and — with deterministic equal-timestamp precedence — an
# older-or-equal active event can never resurrect it (contract §3/§15; P0
# equal-timestamp resurrection).
_TERMINAL_STATES = frozenset({"refunded", "revoked", "expired"})

# ── RevenueCat shadow-canary flip-eligibility classes ───────────────────────
# The `store` a shadow observation originated from decides whether it counts
# toward the shadow->authoritative flip decision. A RevenueCat PROMOTIONAL grant
# (dashboard/API admin entitlement) makes RevenueCat "active" with NO underlying
# store purchase, so in shadow mode it legitimately disagrees with the (correct)
# free legacy projection — it is an admin/transport canary, NOT a store-parity
# canary. Promotional observations are therefore EXCLUDED from the flip gate
# while still retained in lifetime diagnostics.
_RC_STORE_PROMOTIONAL = frozenset({"PROMOTIONAL"})
# RevenueCat's `store` for a synthetic/self-issued canary event: a signed
# integration probe (our own test webhook, or a RevenueCat "TEST_STORE" event)
# that proves the transport/idempotency/authentication path end-to-end but stands
# for NO real customer purchase. Like PROMOTIONAL it makes RevenueCat "active"
# with no underlying store, so in shadow mode it legitimately disagrees with the
# (correct) free legacy projection — counting it as store-parity evidence pins
# `shadow_clean` false forever. It is therefore EXCLUDED from the flip decision,
# but bucketed SEPARATELY from promotional (its own `excluded_synthetic`) so the
# ledger stays honest about which exclusions are admin grants vs. test canaries.
# The observation is retained in the append-only ledger and lifetime diagnostics
# — durably auditable — it simply never qualifies as real store evidence.
_RC_STORE_SYNTHETIC = frozenset({"TEST_STORE"})
# Real customer stores whose events ARE store-parity canaries and stay
# flip-eligible: a disagreement on any of these still BLOCKS the flip. Kept as an
# explicit allowlist (not "anything that isn't promotional/synthetic") so a
# new/unknown store fails closed rather than silently counting as clean.
_RC_STORE_ELIGIBLE = frozenset({
    "APP_STORE", "MAC_APP_STORE", "PLAY_STORE", "AMAZON",
    "STRIPE", "RC_BILLING", "WEB_BILLING", "PADDLE",
})


def _classify_rc_store(store_source: Optional[str]) -> str:
    """Classify a RevenueCat `store` for the shadow flip gate:
      'promotional' – admin/dashboard grant, excluded from the flip decision;
      'synthetic'   – a self-issued/TEST_STORE integration canary: durably
                      auditable but excluded from the flip decision and never
                      counted as real store evidence (its own bucket);
      'eligible'    – a real store-parity canary that counts toward the flip;
      'unknown'     – empty or unrecognized, which FAILS CLOSED (blocks the flip
                      and is never treated as promotional, synthetic or clean).
    Case- and whitespace-insensitive; a non-string/None store coerces to
    'unknown' (fail closed) rather than raising."""
    token = str(store_source or "").strip().upper()
    if not token:
        return "unknown"
    if token in _RC_STORE_PROMOTIONAL:
        return "promotional"
    if token in _RC_STORE_SYNTHETIC:
        return "synthetic"
    if token in _RC_STORE_ELIGIBLE:
        return "eligible"
    return "unknown"


def _rc_store_from_payload(payload_text: Optional[str]) -> Optional[str]:
    """Extract the RevenueCat `store` from a durable event payload (the raw
    webhook JSON) so pre-migration shadow rows can be classified from the same
    body RevenueCat delivered. Returns None on any parse error or a missing
    store — the caller then leaves the row unclassified (fail closed), never
    guessing a store."""
    if not payload_text:
        return None
    try:
        body = json.loads(payload_text)
    except (ValueError, TypeError):
        return None
    if not isinstance(body, dict):
        return None
    event = body.get("event")
    if not isinstance(event, dict):
        return None
    store = event.get("store")
    return str(store) if store else None


# The only ownership types we will build an entitlement grant for. Anything else
# is refused before any DB mutation (contract §4/§6; P0 fail-closed ownership).
_GRANTABLE_OWNERSHIP = frozenset({"PURCHASED", "FAMILY_SHARED"})

# Stripe subscription status → our append-only lifecycle_state.
# past_due keeps access during the dunning grace period; unpaid/canceled revoke it.
_STRIPE_STATUS_TO_LIFECYCLE: dict = {
    "active":             "active",
    "trialing":           "active",
    "past_due":           "active",   # grace period — keep access
    "incomplete":         "active",   # first invoice still pending
    "canceled":           "expired",
    "unpaid":             "expired",  # dunning failed
    "incomplete_expired": "expired",
    "paused":             "expired",
}


class AccountConflictError(Exception):
    """Raised when linking a provider identity or passkey would silently
    merge two distinct accounts. Callers (server.py) should surface this as
    a 409 — merging accounts is a decision a person confirms explicitly,
    never something inferred from a login attempt."""


class DeviceRegistrationProofError(Exception):
    """An existing public device id was presented without its secret proof."""


def _plan_grants_pro(plan: str, subscription_status: Optional[str], coupon_pro_expires_at: Optional[str]) -> bool:
    # Single source of truth for plan/status/coupon entitlement. Every rewrite
    # gate resolves through this (via ``User.is_pro`` / ``Account.is_pro``);
    # there is no second, disagreeing inline check anywhere (the free-tier
    # counter was retired — see ``record_rewrite``). ``past_due`` is the
    # deliberate auto-renew GRACE window: a renewal charge is retrying and the
    # subscription is not yet canceled, so access continues. Once the provider
    # transitions the row to ``canceled``/expired (or a coupon lapses), no
    # branch here matches and every surface fails closed — contract "expired/
    # canceled/non-entitled fail closed; trial auto-renews unless canceled".
    if plan == "pro" and subscription_status in ("active", "trialing", "past_due"):
        return True
    if coupon_pro_expires_at:
        try:
            exp = dt.datetime.fromisoformat(coupon_pro_expires_at)
            if exp > dt.datetime.now(dt.timezone.utc):
                return True
        except (ValueError, TypeError):
            # ValueError: unparseable expiry. TypeError: a *parseable* but
            # timezone-naive expiry — comparing naive to the aware ``now``
            # raises. The in-repo redemption writer always emits aware ISO, but
            # rows can also arrive from non-canonical writers (dict-sourced
            # rows via ``_row_to_user``/``_row_to_account``, account-link
            # copying, migrations, manual grants), so a naive value is
            # reachable. Both cases must deny cleanly here rather than escape
            # as a 500 — the gate owes callers the honest 402.
            pass
    return False


@dataclass
class Account:
    """A signed-in person, spanning every device they've linked via Apple/
    Google sign-in. Plan/subscription live here once an account exists —
    see the `accounts` table comment in SCHEMA for why they're duplicated
    on `users` too."""

    id: str
    apple_sub: Optional[str]
    google_sub: Optional[str]
    email: Optional[str]
    plan: str
    stripe_customer_id: Optional[str]
    stripe_subscription_id: Optional[str]
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    coupon_pro_expires_at: Optional[str]
    created_at: str
    updated_at: str
    daily_count: int = 0
    daily_day: Optional[str] = None
    supabase_sub: Optional[str] = None
    deleted_at: Optional[str] = None
    # Build 114 — email login identity. See the `accounts` SCHEMA comment.
    email_normalized: Optional[str] = None
    email_verified_at: Optional[str] = None

    @property
    def is_pro(self) -> bool:
        return _plan_grants_pro(self.plan, self.subscription_status, self.coupon_pro_expires_at)

    @property
    def email_is_verified(self) -> bool:
        """True only when this account's address has been proven owned.

        Verification is a fact about the ADDRESS, never about entitlement:
        nothing in this property or its callers grants Pro. `is_pro` remains
        the sole entitlement answer and reads only plan/subscription/coupon.
        """
        return bool(self.email_verified_at)

    @property
    def lifecycle_state(self) -> str:
        """The queryable registration state of this account.

        * ``disabled``  — tombstoned by account deletion.
        * ``verified``  — carries a proven identity (a verified email, or an
          Apple/Google/Supabase provider subject, all of which are
          provider-proven at the point we accept them).
        * ``pending``   — an email registration exists but ownership has not
          been proven yet. Private surfaces stay closed in this state.
        * ``anonymous`` — the device-first auto-account; no identity at all.
        """
        if self.deleted_at:
            return "disabled"
        if self.apple_sub or self.google_sub or self.supabase_sub or self.email_is_verified:
            return "verified"
        if self.email or self.email_normalized:
            return "pending"
        return "anonymous"

    @property
    def is_identified(self) -> bool:
        """True once this account carries a real sign-in identity (Apple/
        Google/email). An anonymous auto-account created at registration is
        NOT identified: build 91 gives every device a canonical account UUID
        (the entitlement principal), but an anonymous account remains
        non-entitled and fails closed — the account only becomes the billing
        and entitlement source of truth once the
        person actually signs in. Passkey-only accounts always carry an email
        at registration, so the columns are a sufficient signal. A Supabase web
        sign-in is an identity too (verified Apple/Google via Supabase).

        Build 114 keeps `email` meaning exactly what it has always meant here:
        a PROVEN address. An email registration that has not been verified yet
        writes only `email_normalized` (for collision lookup) and leaves
        `email` NULL, so a pending registration is deliberately NOT identified
        — its private surfaces stay closed and, if the person later signs in
        with Apple/Google, `_resolve_provider_signin` upgrades that same
        account in place instead of splitting their history."""
        return bool(self.apple_sub or self.google_sub or self.supabase_sub or self.email)


@dataclass
class WebAuthnCredential:
    """One registered passkey. `public_key` is the raw COSE-encoded key
    bytes py_webauthn hands back from registration — needed to verify every
    future login assertion from this credential."""

    credential_id: str  # base64url
    account_id: str
    public_key: bytes
    sign_count: int
    transports: list[str]
    nickname: Optional[str]
    created_at: str
    last_used_at: Optional[str]


@dataclass
class User:
    device_id: str
    api_token: str
    plan: str
    stripe_customer_id: Optional[str]
    stripe_subscription_id: Optional[str]
    subscription_status: Optional[str]
    subscription_renews_at: Optional[str]
    daily_count: int
    daily_day: Optional[str]
    created_at: str
    updated_at: str
    coupon_pro_expires_at: Optional[str] = None
    account_id: Optional[str] = None
    account: Optional[Account] = None
    # True when the canonical account holds an active Apple entitlement grant
    # (direct purchase or family beneficiary). Populated by _attach_account.
    provider_entitlement_active: bool = False

    @property
    def is_pro(self) -> bool:
        # An Apple entitlement grant attaches to the canonical account —
        # anonymous or identified — and always counts (build-91 §4/§6).
        if self.provider_entitlement_active:
            return True
        # An IDENTIFIED (signed-in) account is the billing source of truth: a
        # device that signed in inherits Pro from the account even if that
        # device never itself had a subscription.
        if self.account is not None and self.account.is_identified and self.account.is_pro:
            return True
        # Device coupon fields are bounded legacy compatibility for an
        # anonymous install only. Once identified, account authority is
        # exclusive; link-time convergence preserves a valid legacy grant.
        if self.account is not None and self.account.is_identified:
            return _plan_grants_pro(self.plan, self.subscription_status, None)
        return _plan_grants_pro(self.plan, self.subscription_status, self.coupon_pro_expires_at)

    @property
    def plan_resolved(self) -> str:
        """`plan`, but resolved through the linked account once identified."""
        if self.account is not None and self.account.is_identified:
            return self.account.plan
        return self.plan


@dataclass
class DeviceRegistration:
    user: User
    device_credential: Optional[str] = None
    migrated_legacy_token: bool = False


@dataclass
class AppleEntitlementResult:
    """Outcome of applying one verified Apple transaction. `outcome` is one of:
    'direct_granted', 'family_granted', 'legacy_granted' (all entitle the
    account), 'conflict' (bound/claimed elsewhere), 'revoked' (a stale signed
    transaction that must not resurrect a terminated purchase), 'not_active'
    (verified but expired/revoked evidence)."""
    outcome: str
    detail: str = ""
    purchase_id: Optional[str] = None

    @property
    def granted(self) -> bool:
        return self.outcome in ("direct_granted", "family_granted", "legacy_granted")


# States a Google Play subscription lineage can reach that must NEVER be
# resurrected by a later apparently-active re-query or a replayed token
# (contract §3; hostile "stale active after revoke" / "linked replacement").
# 'expired' is soft-terminal instead: a strictly-newer active re-query on the
# same token may legitimately supersede it (rare, but deterministic).
_GOOGLE_HARD_TERMINAL = frozenset({"refunded", "revoked", "replaced"})


@dataclass
class GoogleEntitlementResult:
    """Outcome of projecting one verified Google Play subscription snapshot.

    `outcome` is one of: 'granted' (an active/grace/canceled-with-future-expiry
    purchase bound to the account entitles it), 'not_active' (verified but the
    subscription is on-hold/paused/pending/expired/revoked so no entitlement),
    'conflict' (the purchase is bound to a different account via
    obfuscatedExternalAccountId or a prior first-claim), 'stale' (older or
    hard-terminal-superseded evidence that must not resurrect entitlement),
    'unbound' (a valid purchase with no resolvable beneficiary yet — recorded so
    a later authenticated sync can bind it, but nothing is granted)."""

    outcome: str
    detail: str = ""
    purchase_id: Optional[str] = None
    lifecycle_state: Optional[str] = None
    acknowledge_pending: bool = False

    @property
    def granted(self) -> bool:
        return self.outcome == "granted"


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------


class Store:
    def __init__(self, path: str):
        self.path = path
        self._conn = sqlite3.connect(
            path,
            check_same_thread=False,
            isolation_level=None,
            timeout=10.0,
        )
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")
        self._closed = False
        self._init_schema()

    # ---- lifecycle ----

    def _init_schema(self) -> None:
        with contextlib.closing(self._conn.cursor()) as c:
            c.executescript(SCHEMA)
        for stmt in (
            # Build 117 app-review compatibility: per-coupon anonymous bypass.
            "ALTER TABLE coupons ADD COLUMN anonymous_eligible INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE users ADD COLUMN stripe_customer_id TEXT",
            "ALTER TABLE users ADD COLUMN stripe_subscription_id TEXT",
            "ALTER TABLE users ADD COLUMN subscription_status TEXT",
            "ALTER TABLE users ADD COLUMN subscription_renews_at TEXT",
            "ALTER TABLE users ADD COLUMN coupon_pro_expires_at TEXT",
            "ALTER TABLE users ADD COLUMN account_id TEXT REFERENCES accounts(id)",
            "ALTER TABLE accounts ADD COLUMN daily_count INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE accounts ADD COLUMN daily_day TEXT",
            "ALTER TABLE users ADD COLUMN device_credential_hash TEXT",
            "ALTER TABLE users ADD COLUMN previous_api_token TEXT",
            "ALTER TABLE users ADD COLUMN previous_api_token_expires_at TEXT",
            "ALTER TABLE accounts ADD COLUMN supabase_sub TEXT",
            "ALTER TABLE accounts ADD COLUMN deleted_at TEXT",
            # Build 114 — email login identity. `email_normalized` is a
            # case-folded copy of `email` used ONLY to detect collisions and to
            # look up "is this address already spoken for"; it is deliberately
            # NOT unique and never a merge key (see upsert_account_by_provider).
            # `email_verified_at` is the single fact that turns a pending
            # registration into a usable login identity.
            "ALTER TABLE accounts ADD COLUMN email_normalized TEXT",
            "ALTER TABLE accounts ADD COLUMN email_verified_at TEXT",
            # Build 114 remediation. `source_surface` / `app_build` became
            # immutable registration facts, so recency needed somewhere honest
            # to live; `provider_subject` is the pre-verification claim that
            # makes the anonymous upgrade survive the verification click. See
            # the `account_registrations` SCHEMA comment for each.
            "ALTER TABLE account_registrations ADD COLUMN last_seen_surface TEXT",
            "ALTER TABLE account_registrations ADD COLUMN last_seen_app_build TEXT",
            "ALTER TABLE account_registrations ADD COLUMN provider_subject TEXT",
            # Normalized code is held server-side while the address is pending.
            # It is consumed only by mark_email_verified's transaction.
            "ALTER TABLE account_registrations ADD COLUMN pending_coupon_code TEXT",
            # A signed-out device row is retired: its credential is gone and its
            # bearer is rotated, so nothing can prove itself back into it.
            # Recording WHEN it was retired is what lets `register_device`
            # re-issue the slot as a brand-new device instead of answering a
            # permanent 409 (see `sign_out_device`).
            "ALTER TABLE users ADD COLUMN signed_out_at TEXT",
            # Verified plan price for a store purchase, captured ONLY where the
            # provider hands us an authoritative, already-normalized amount
            # (Stripe's recurring price `unit_amount` + ISO `currency`).
            # `amount_minor` is integer minor units (e.g. 399 = $3.99); it is
            # NEVER a parsed amount string and NEVER a raw transaction id. Left
            # NULL for providers whose verified payloads we don't normalize
            # (Apple/Google here) so the timeline shows a price only when it is
            # provably correct, never a guess.
            "ALTER TABLE provider_purchases ADD COLUMN amount_minor INTEGER",
            "ALTER TABLE provider_purchases ADD COLUMN currency TEXT",
        ):
            with contextlib.suppress(sqlite3.OperationalError):
                self._conn.execute(stmt)
        # Created here rather than in SCHEMA for the same reason the
        # supabase_sub index is: on a migrated DB the CREATE TABLE is a no-op,
        # so the column does not exist yet when SCHEMA's executescript runs.
        with contextlib.suppress(sqlite3.OperationalError):
            self._conn.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_account_registrations_provider_subject"
                " ON account_registrations(provider_subject)"
                " WHERE provider_subject IS NOT NULL"
            )
        # Non-unique: two DIFFERENT provider subjects may legitimately present
        # the same address (distinct Supabase users across projects/eras). We
        # keep them as separate accounts and audit the collision rather than
        # merging — a unique index here would instead crash the second person
        # out of their own account.
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_accounts_email_normalized "
            "ON accounts(email_normalized)"
        )
        self._conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_users_previous_token ON users(previous_api_token)"
        )
        for stmt in (
            "ALTER TABLE stripe_events ADD COLUMN processed_at TEXT",
            # Build 126 corrective: the originating RevenueCat `store` per shadow
            # observation, so a PROMOTIONAL admin grant can be excluded from the
            # shadow->authoritative flip decision while staying in lifetime
            # diagnostics. Additive; pre-existing rows are NULL here and are
            # recovered from the durable revenuecat_events payload by
            # _backfill_revenuecat_shadow_store_source below.
            "ALTER TABLE revenuecat_shadow_observations ADD COLUMN store_source TEXT",
            # Re-query reconciliation annotation: when set, a later check of
            # RevenueCat's CURRENT truth confirmed this historical disagreement is
            # stale (RC no longer supports it — its current access now agrees with
            # the legacy projection). Additive provenance only; the observation's
            # original facts (revenuecat_active/legacy_active/agree) are never
            # rewritten. The flip summary then counts a reconciled row as an
            # agreement, so a purchase that has since expired stops blocking the
            # cutover while a REAL standing disagreement (RC still active) keeps
            # blocking because it is never reconciled.
            "ALTER TABLE revenuecat_shadow_observations ADD COLUMN reconciled_at TEXT",
        ):
            with contextlib.suppress(sqlite3.OperationalError):
                self._conn.execute(stmt)
        # Must run after ALTER TABLE adds supabase_sub: on migrated DBs the
        # CREATE TABLE IF NOT EXISTS is a no-op, so the column doesn't exist
        # when SCHEMA's executescript runs. Placing the index here, after the
        # column migration, guarantees it works for both fresh and existing DBs.
        self._conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_supabase_sub ON accounts(supabase_sub)"
        )
        self._backfill_email_identity()
        self._backfill_account_coupons()
        self._backfill_stripe_trial_ledger()
        self._backfill_revenuecat_shadow_store_source()
        self._seed_feature_flags()

    def _backfill_account_coupons(self) -> None:
        """Additively project valid legacy device grants into their accounts.

        Legacy rows and counters are audit facts and are never rewritten.
        Re-running is harmless: max-expiry and INSERT OR IGNORE are monotonic.
        """
        cur = self._conn.cursor()
        now = _now_iso()
        cur.execute("BEGIN IMMEDIATE")
        try:
            cur.execute(
                """SELECT account_id, MAX(coupon_pro_expires_at) AS expires_at
                     FROM users
                    WHERE account_id IS NOT NULL
                      AND coupon_pro_expires_at IS NOT NULL
                      AND coupon_pro_expires_at > ?
                    GROUP BY account_id""",
                (now,),
            )
            for row in cur.fetchall():
                cur.execute(
                    """UPDATE accounts
                          SET coupon_pro_expires_at =
                                CASE WHEN coupon_pro_expires_at IS NULL
                                           OR coupon_pro_expires_at < ?
                                     THEN ? ELSE coupon_pro_expires_at END,
                              updated_at = ?
                        WHERE id = ?""",
                    (row["expires_at"], row["expires_at"], now, row["account_id"]),
                )
            cur.execute(
                """SELECT DISTINCT u.account_id, r.code, r.redeemed_at,
                                  u.coupon_pro_expires_at
                     FROM coupon_redemptions r
                     JOIN users u ON u.device_id = r.device_id
                    WHERE u.account_id IS NOT NULL
                      AND u.coupon_pro_expires_at IS NOT NULL
                      AND u.coupon_pro_expires_at > ?""",
                (now,),
            )
            for row in cur.fetchall():
                cur.execute(
                    """INSERT OR IGNORE INTO account_coupon_redemptions
                           (account_id, code, redeemed_at, expires_at)
                       VALUES (?, ?, ?, ?)""",
                    (row["account_id"], row["code"], row["redeemed_at"], row["coupon_pro_expires_at"]),
                )
            cur.execute("COMMIT")
        except Exception:
            with contextlib.suppress(sqlite3.Error):
                cur.execute("ROLLBACK")
            raise

    def _backfill_revenuecat_shadow_store_source(self) -> None:
        """Classify shadow observations written before the `store_source` column
        existed (build 126 corrective), so a pre-upgrade PROMOTIONAL admin grant
        is distinguishable from a real store-parity canary and the flip gate is
        computed from the RIGHT population.

        The store is recovered from the durable revenuecat_events row that the
        observation was derived from — its already-extracted `store_source`
        column first, then the raw `payload` JSON (the same body RevenueCat
        delivered) as a fallback — so this is a deterministic backfill from
        durable event evidence, never a guess.

        Idempotent and evidence-preserving: only rows whose `store_source` IS
        NULL are touched, re-running re-derives the same value, a non-NULL value
        is never rewritten, and a row we cannot classify is LEFT NULL (it then
        fails closed in the flip summary rather than being assumed clean).
        """
        cur = self._conn.cursor()
        cur.execute("BEGIN IMMEDIATE")
        try:
            cur.execute(
                "SELECT o.id AS oid, e.store_source AS col_store, e.payload AS payload "
                "  FROM revenuecat_shadow_observations o "
                "  JOIN revenuecat_events e ON e.event_id = o.event_id "
                " WHERE o.store_source IS NULL"
            )
            for row in cur.fetchall():
                store = row["col_store"] or _rc_store_from_payload(row["payload"])
                if store:
                    cur.execute(
                        "UPDATE revenuecat_shadow_observations SET store_source = ? WHERE id = ?",
                        (str(store), row["oid"]),
                    )
            cur.execute("COMMIT")
        except Exception:
            with contextlib.suppress(sqlite3.Error):
                cur.execute("ROLLBACK")
            raise

    def _backfill_email_identity(self) -> None:
        """Make existing accounts truthful under the Build 114 columns.

        Before Build 114 an address was written to `accounts.email` ONLY after
        a provider had already proven it (Apple/Google relay addresses, a
        Supabase token whose `email_verified` claim was true, or passkey
        registration). So every pre-existing non-null `email` is, by
        construction, a verified address — backfilling `email_verified_at`
        from it states a fact that was already true rather than inventing one.

        Idempotent and additive: rows that already carry the columns are left
        alone, and a tombstoned account (identity columns cleared) has no
        `email` to backfill, so deletion stays terminal.

        The normalized column is computed in PYTHON, through the same
        ``normalize_email`` every lookup uses, rather than with SQL
        ``lower(trim(...))``. SQL's version does not do NFKC folding or reject
        a non-mailbox, so a legacy row backfilled by SQL could store a key that
        a later lookup would never produce — the address would silently stop
        matching itself. An address that does not normalize is left NULL:
        unmatched is honest, a wrong key is not.
        """
        with contextlib.suppress(sqlite3.OperationalError):
            self._conn.execute(
                """UPDATE accounts
                      SET email_verified_at = COALESCE(updated_at, created_at)
                    WHERE email IS NOT NULL
                      AND email <> ''
                      AND email_verified_at IS NULL"""
            )
        with contextlib.suppress(sqlite3.OperationalError):
            cur = self._conn.cursor()
            cur.execute(
                """SELECT id, email FROM accounts
                    WHERE email IS NOT NULL
                      AND email <> ''
                      AND email_normalized IS NULL"""
            )
            for row in cur.fetchall():
                normalized = normalize_email(row["email"])
                if normalized:
                    self._conn.execute(
                        "UPDATE accounts SET email_normalized = ? WHERE id = ?",
                        (normalized, row["id"]),
                    )

    def _backfill_stripe_trial_ledger(self) -> None:
        """Conservatively consume every legacy Stripe-touching principal.

        Tombstones are intentionally included. Conflicting legacy customer
        ownership is audited and the first binding is retained; no row is
        silently reassigned. The whole migration is replay-safe.
        """
        cur = self._conn.cursor()
        now = _now_iso()
        cur.execute("BEGIN IMMEDIATE")
        try:
            cur.execute(
                """SELECT a.id account_id, a.stripe_customer_id customer_id
                     FROM accounts a
                    WHERE a.stripe_customer_id IS NOT NULL
                       OR a.stripe_subscription_id IS NOT NULL
                       OR a.subscription_status IS NOT NULL
                   UNION
                   SELECT u.account_id, u.stripe_customer_id
                     FROM users u
                    WHERE u.account_id IS NOT NULL
                      AND (u.stripe_customer_id IS NOT NULL
                       OR u.stripe_subscription_id IS NOT NULL
                       OR u.subscription_status IS NOT NULL)
                   UNION
                   SELECT p.app_account_token, NULL
                     FROM provider_purchases p
                    WHERE p.provider='stripe' AND p.app_account_token IS NOT NULL"""
            )
            for row in cur.fetchall():
                account_id, customer_id = row["account_id"], row["customer_id"]
                if account_id:
                    self._insert_consumed_scope(
                        cur, "account", account_id, now, account_id, customer_id, None
                    )
                if customer_id:
                    self._insert_consumed_scope(
                        cur, "customer", customer_id, now, account_id, customer_id, None
                    )
                    if account_id:
                        self._bind_customer_tx(cur, account_id, customer_id, now)
            cur.execute("COMMIT")
        except Exception:
            with contextlib.suppress(sqlite3.Error):
                cur.execute("ROLLBACK")
            raise

    def _seed_feature_flags(self) -> None:
        cur = self._conn.cursor()
        for key, enabled, plan_required, rollout_pct, user_controllable, description in _DEFAULT_FLAGS:
            cur.execute(
                """INSERT OR IGNORE INTO feature_flags
                   (key, enabled, plan_required, rollout_pct, user_controllable, description)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (key, enabled, plan_required, rollout_pct, user_controllable, description),
            )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        # wait=True matters: log_usage() fire-and-forgets onto this executor
        # (callers don't block on it), so a queued write can still be
        # in-flight when shutdown starts. Closing self._conn out from under
        # that write is a use-after-close race in the sqlite3 C extension —
        # observed as an intermittent segfault, not a clean exception,
        # because it's a native crash rather than a Python-level error.
        with contextlib.suppress(Exception):
            self._executor.shutdown(wait=True)
        with contextlib.suppress(Exception):
            self._conn.close()

    def _ensure_open(self) -> None:
        if self._closed or self._conn is None:
            self._conn = sqlite3.connect(
                self.path,
                check_same_thread=False,
                isolation_level=None,
                timeout=10.0,
            )
            self._conn.row_factory = sqlite3.Row
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA foreign_keys=ON")
            self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")
            self._init_schema()
            self._closed = False

    def _ensure_executor(self) -> None:
        self._ensure_open()
        if self._executor is None or getattr(self._executor, "_shutdown", False):
            self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="db")

    def _run(self, fn, /, *args, **kwargs):
        def wrapper():
            try:
                return fn(*args, **kwargs)
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    self._conn.execute("ROLLBACK")
                raise

        self._ensure_executor()
        return self._executor.submit(wrapper)

    # ---- user / device ----

    def register_device(
        self,
        device_id: Optional[str] = None,
        *,
        device_credential: Optional[str] = None,
        bearer_token: Optional[str] = None,
        legacy_grace_seconds: int = 86400,
    ) -> DeviceRegistration:
        now = _now_iso()

        def _do() -> DeviceRegistration:
            cur = self._conn.cursor()
            if device_id:
                cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
                row = cur.fetchone()
                if row:
                    credential_hash = row["device_credential_hash"]
                    credential_ok = bool(
                        credential_hash
                        and device_credential
                        and secrets.compare_digest(
                            credential_hash,
                            _hash_device_credential(device_credential),
                        )
                    )
                    if credential_ok:
                        user = _row_to_user(row)
                        # Defensive backfill: a device that predates the
                        # account-first contract (or a legacy row) must still
                        # end up with a canonical account_id (contract §1).
                        self._ensure_account(cur, user, now)
                        return DeviceRegistration(user=user)

                    legacy_ok = bool(
                        bearer_token
                        and not credential_hash
                        and secrets.compare_digest(row["api_token"], bearer_token)
                    )
                    # A RETIRED row (signed out) is re-issuable as a brand-new
                    # device. Nothing can prove itself back into it — sign-out
                    # nulled the credential and rotated the bearer — so without
                    # this the device id answered 409 forever, and a client that
                    # keeps its device id across a sign-out (or a person
                    # reinstalling on the same handset) could never register
                    # again. Re-issuing is safe precisely because the row is
                    # empty: sign-out already unlinked the account and cleared
                    # the entitlement mirror, so the claimant inherits a fresh
                    # anonymous account and nothing else. A row that was NOT
                    # signed out still requires proof, so this widens nothing
                    # for a live device.
                    if row["account_id"] is None and _row_signed_out(row):
                        return self._reissue_signed_out_device(cur, device_id, now)

                    if legacy_ok:
                        credential = _new_device_credential()
                        token = _new_token()
                        expires_at = (
                            dt.datetime.now(dt.timezone.utc)
                            + dt.timedelta(seconds=max(0, legacy_grace_seconds))
                        ).isoformat()
                        cur.execute("BEGIN IMMEDIATE")
                        try:
                            cur.execute(
                                """UPDATE users
                                      SET api_token=?, device_credential_hash=?,
                                          previous_api_token=?, previous_api_token_expires_at=?,
                                          updated_at=?
                                    WHERE device_id=? AND api_token=?
                                      AND device_credential_hash IS NULL""",
                                (
                                    token,
                                    _hash_device_credential(credential),
                                    row["api_token"],
                                    expires_at,
                                    now,
                                    device_id,
                                    bearer_token,
                                ),
                            )
                            if cur.rowcount != 1:
                                cur.execute("ROLLBACK")
                                raise DeviceRegistrationProofError()
                            cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
                            user = _row_to_user(cur.fetchone())
                            self._ensure_account(cur, user, now)
                            cur.execute("COMMIT")
                        except DeviceRegistrationProofError:
                            raise
                        except Exception:
                            with contextlib.suppress(sqlite3.Error):
                                cur.execute("ROLLBACK")
                            raise
                        return DeviceRegistration(
                            user=user,
                            device_credential=credential,
                            migrated_legacy_token=True,
                        )
                    raise DeviceRegistrationProofError()

            did = device_id or str(uuid.uuid4())
            token = _new_token()
            credential = _new_device_credential()
            # Registration atomically mints the canonical (anonymous) account
            # UUID and the device row that references it, so no write ever
            # leaves an unlinked device (contract §1).
            cur.execute("BEGIN IMMEDIATE")
            try:
                account_id = _insert_anonymous_account(cur, now)
                cur.execute(
                    """INSERT INTO users
                           (device_id, api_token, device_credential_hash, plan,
                            account_id, created_at, updated_at)
                         VALUES (?, ?, ?, 'free', ?, ?, ?)""",
                    (did, token, _hash_device_credential(credential), account_id, now, now),
                )
                cur.execute("SELECT * FROM users WHERE device_id = ?", (did,))
                user = _row_to_user(cur.fetchone())
                cur.execute("COMMIT")
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
            self._attach_account(cur, user)
            return DeviceRegistration(user=user, device_credential=credential)

        return self._run(_do).result()

    def _reissue_signed_out_device(
        self, cur: sqlite3.Cursor, device_id: str, now: str
    ) -> DeviceRegistration:
        """Re-issue a retired device slot as a brand-new anonymous device.

        Everything a fresh `/v1/register` would produce: a new bearer, a new
        durable credential, and a NEW canonical anonymous account. Nothing from
        the retired occupant survives — the counters are zeroed and the
        entitlement mirror is already clear — so this is a re-registration, not
        a recovery, and it can never be a way back into the account the row was
        signed out of. That account is reachable only by signing in.
        """
        token = _new_token()
        credential = _new_device_credential()
        cur.execute("BEGIN IMMEDIATE")
        try:
            account_id = _insert_anonymous_account(cur, now)
            cur.execute(
                """UPDATE users
                      SET api_token = ?,
                          device_credential_hash = ?,
                          previous_api_token = NULL,
                          previous_api_token_expires_at = NULL,
                          account_id = ?,
                          signed_out_at = NULL,
                          plan = 'free',
                          stripe_subscription_id = NULL,
                          subscription_status = NULL,
                          subscription_renews_at = NULL,
                          coupon_pro_expires_at = NULL,
                          daily_count = 0,
                          daily_day = NULL,
                          updated_at = ?
                    WHERE device_id = ?
                      AND account_id IS NULL
                      AND device_credential_hash IS NULL
                      AND signed_out_at IS NOT NULL""",
                (token, _hash_device_credential(credential), account_id, now, device_id),
            )
            if cur.rowcount != 1:
                # Someone else re-issued this slot between our read and our
                # write. Fail closed rather than handing out a second bearer.
                cur.execute("ROLLBACK")
                raise DeviceRegistrationProofError()
            cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
            user = _row_to_user(cur.fetchone())
            cur.execute("COMMIT")
        except DeviceRegistrationProofError:
            raise
        except Exception:
            with contextlib.suppress(sqlite3.Error):
                cur.execute("ROLLBACK")
            raise
        self._attach_account(cur, user)
        return DeviceRegistration(user=user, device_credential=credential)

    def _ensure_account(self, cur: sqlite3.Cursor, user: User, now: str) -> None:
        """Guarantee `user` references a canonical account, minting an
        anonymous one in place if a legacy/pre-contract row has none. Runs on
        the DB executor thread with the caller's cursor; mutates `user`."""
        if not user.account_id:
            account_id = _insert_anonymous_account(cur, now)
            cur.execute(
                "UPDATE users SET account_id = ?, updated_at = ? WHERE device_id = ?",
                (account_id, now, user.device_id),
            )
            user.account_id = account_id
        self._attach_account(cur, user)

    def _attach_account(self, cur: sqlite3.Cursor, user: User) -> User:
        """Populate `user.account` and the provider-entitlement flag when the
        device is linked to one. Called inline (same cursor/thread) rather than
        through another `_run` — this already runs on the DB executor thread."""
        if user.account_id:
            cur.execute("SELECT * FROM accounts WHERE id = ?", (user.account_id,))
            acct_row = cur.fetchone()
            if acct_row:
                user.account = _row_to_account(acct_row)
            user.provider_entitlement_active = _account_has_active_grant(cur, user.account_id)
        return user

    def get_by_token(self, token: str) -> Optional[User]:
        def _do() -> Optional[User]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT * FROM users
                     WHERE api_token = ?
                        OR (previous_api_token = ?
                            AND previous_api_token_expires_at > ?)""",
                (token, token, _now_iso()),
            )
            row = cur.fetchone()
            return self._attach_account(cur, _row_to_user(row)) if row else None

        return self._run(_do).result()

    def get_by_device(self, device_id: str) -> Optional[User]:
        def _do() -> Optional[User]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
            row = cur.fetchone()
            return self._attach_account(cur, _row_to_user(row)) if row else None

        return self._run(_do).result()

    def ensure_account(self, device_id: str) -> Optional[User]:
        """Return the device's user, minting + linking a canonical anonymous
        account first if a legacy row still has none (contract §1). Idempotent."""

        def _do() -> Optional[User]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM users WHERE device_id = ?", (device_id,))
            row = cur.fetchone()
            if not row:
                return None
            user = _row_to_user(row)
            self._ensure_account(cur, user, _now_iso())
            return user

        return self._run(_do).result()

    def rotate_token(self, device_id: str) -> Optional[str]:
        def _do() -> Optional[str]:
            cur = self._conn.cursor()
            token = _new_token()
            cur.execute(
                """UPDATE users
                      SET api_token=?, previous_api_token=NULL,
                          previous_api_token_expires_at=NULL, updated_at=?
                    WHERE device_id=?""",
                (token, _now_iso(), device_id),
            )
            return token if cur.rowcount else None

        return self._run(_do).result()

    def _record_trial_conflict(
        self, cur, kind, scope, scope_id, account_id, customer_id, subscription_id, detail
    ) -> None:
        cur.execute(
            """INSERT OR IGNORE INTO stripe_trial_conflicts
               (id, conflict_kind, scope, scope_id, account_id, customer_id,
                subscription_id, detail, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (str(uuid.uuid4()), kind, scope, scope_id, account_id, customer_id,
             subscription_id, detail, _now_iso()),
        )

    def _bind_customer_tx(self, cur, account_id: str, customer_id: str, now: str) -> bool:
        cur.execute(
            """INSERT OR IGNORE INTO stripe_customer_bindings
               (customer_id, account_id, created_at, updated_at) VALUES (?, ?, ?, ?)""",
            (customer_id, account_id, now, now),
        )
        cur.execute(
            "SELECT customer_id, account_id FROM stripe_customer_bindings "
            "WHERE customer_id=? OR account_id=?",
            (customer_id, account_id),
        )
        bindings = cur.fetchall()
        winner = next(
            (r for r in bindings
             if r["customer_id"] == customer_id and r["account_id"] == account_id), None
        )
        if winner is None:
            self._record_trial_conflict(
                cur, "customer_binding", "customer", customer_id, account_id,
                customer_id, None, "customer or account is already bound"
            )
            return False
        cur.execute(
            """UPDATE accounts SET stripe_customer_id=COALESCE(stripe_customer_id, ?),
                   updated_at=? WHERE id=? AND
                   (stripe_customer_id IS NULL OR stripe_customer_id=?)""",
            (customer_id, now, account_id, customer_id),
        )
        return True

    def attach_account_stripe_customer(self, account_id: str, customer_id: str) -> bool:
        def _do() -> bool:
            cur = self._conn.cursor()
            cur.execute("BEGIN IMMEDIATE")
            try:
                result = self._bind_customer_tx(cur, account_id, customer_id, _now_iso())
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
        return self._run(_do).result()

    def attach_stripe_customer(self, device_id: str, customer_id: str) -> bool:
        user = self.get_by_device(device_id)
        return bool(
            user and user.account_id
            and self.attach_account_stripe_customer(user.account_id, customer_id)
        )

    def get_stripe_customer_binding(self, account_id: str) -> Optional[str]:
        def _do():
            row = self._conn.execute(
                "SELECT customer_id FROM stripe_customer_bindings WHERE account_id=?",
                (account_id,),
            ).fetchone()
            return row["customer_id"] if row else None
        return self._run(_do).result()

    def reserve_stripe_trial(self, *, account_id: str, customer_id: Optional[str]) -> bool:
        """Atomically reserve account and existing-customer scopes."""
        def _do() -> bool:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                scopes = [("account", account_id)]
                if customer_id:
                    scopes.append(("customer", customer_id))
                for scope, scope_id in scopes:
                    row = cur.execute(
                        "SELECT state FROM stripe_trial_ledger WHERE scope=? AND scope_id=?",
                        (scope, scope_id),
                    ).fetchone()
                    if row and row["state"] != "released":
                        cur.execute("COMMIT")
                        return False
                for scope, scope_id in scopes:
                    cur.execute(
                        """INSERT INTO stripe_trial_ledger
                           (scope, scope_id, state, account_id, customer_id,
                            reserved_at, updated_at)
                           VALUES (?, ?, 'reserved', ?, ?, ?, ?)
                           ON CONFLICT(scope, scope_id) DO UPDATE SET
                             state='reserved', session_id=NULL, subscription_id=NULL,
                             account_id=excluded.account_id,
                             customer_id=excluded.customer_id,
                             reserved_at=excluded.reserved_at,
                             updated_at=excluded.updated_at
                           WHERE stripe_trial_ledger.state='released'""",
                        (scope, scope_id, account_id, customer_id, now, now),
                    )
                    if cur.rowcount != 1:
                        raise RuntimeError("trial reservation conflict")
                cur.execute("COMMIT")
                return True
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
        return self._run(_do).result()

    def attach_trial_session(self, account_id: str, session_id: str) -> None:
        def _do():
            self._conn.execute(
                """UPDATE stripe_trial_ledger SET session_id=?, updated_at=?
                   WHERE account_id=? AND state='reserved' AND session_id IS NULL""",
                (session_id, _now_iso(), account_id),
            )
        self._run(_do).result()

    def reserve_customer_scope_for_account(self, account_id: str, customer_id: str) -> bool:
        """Add a newly-created/bound customer to an existing account reservation."""
        def _do():
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                account = cur.execute(
                    """SELECT state FROM stripe_trial_ledger
                       WHERE scope='account' AND scope_id=?""", (account_id,)
                ).fetchone()
                if not account or account["state"] != "reserved":
                    cur.execute("COMMIT")
                    return False
                cur.execute(
                    """INSERT INTO stripe_trial_ledger
                       (scope, scope_id, state, account_id, customer_id,
                        reserved_at, updated_at)
                       VALUES ('customer', ?, 'reserved', ?, ?, ?, ?)
                       ON CONFLICT(scope, scope_id) DO UPDATE SET
                         state='reserved', account_id=excluded.account_id,
                         customer_id=excluded.customer_id,
                         reserved_at=excluded.reserved_at, updated_at=excluded.updated_at
                       WHERE stripe_trial_ledger.state='released'""",
                    (customer_id, account_id, customer_id, now, now),
                )
                ok = cur.rowcount == 1
                cur.execute("COMMIT")
                return ok
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
        return self._run(_do).result()

    def release_trial_session(self, session_id: str) -> int:
        """Release only an exact, definitive Checkout expiry; consumed is terminal."""
        def _do():
            cur = self._conn.execute(
                """UPDATE stripe_trial_ledger SET state='released', updated_at=?
                   WHERE session_id=? AND state='reserved'""",
                (_now_iso(), session_id),
            )
            return cur.rowcount
        return self._run(_do).result()

    def _insert_consumed_scope(
        self, cur, scope, scope_id, now, account_id, customer_id, subscription_id
    ) -> bool:
        row = cur.execute(
            "SELECT state, account_id, customer_id, subscription_id "
            "FROM stripe_trial_ledger "
            "WHERE scope=? AND scope_id=?",
            (scope, scope_id),
        ).fetchone()
        conflict = bool(
            row and row["state"] == "consumed"
            and ((row["subscription_id"] and
                  row["subscription_id"] != subscription_id)
                 or (row["account_id"] and row["account_id"] != account_id)
                 or (row["customer_id"] and row["customer_id"] != customer_id))
        )
        cur.execute(
            """INSERT INTO stripe_trial_ledger
               (scope, scope_id, state, subscription_id, account_id, customer_id,
                reserved_at, consumed_at, updated_at)
               VALUES (?, ?, 'consumed', ?, ?, ?, ?, ?, ?)
               ON CONFLICT(scope, scope_id) DO UPDATE SET
                 state='consumed',
                 subscription_id=COALESCE(stripe_trial_ledger.subscription_id,
                                          excluded.subscription_id),
                 consumed_at=COALESCE(stripe_trial_ledger.consumed_at,
                                      excluded.consumed_at),
                 updated_at=excluded.updated_at
               WHERE stripe_trial_ledger.state != 'consumed'""",
            (scope, scope_id, subscription_id, account_id, customer_id, now, now, now),
        )
        return conflict

    def consume_stripe_trial(
        self, *, account_id: str, customer_id: str, subscription_id: str,
        fingerprint: Optional[str],
    ) -> bool:
        """Consume all observed scopes; return True on cross-principal reuse."""
        def _do():
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                conflict = False
                for scope, scope_id in (
                    ("account", account_id), ("customer", customer_id),
                    ("fingerprint", fingerprint),
                ):
                    if not scope_id:
                        continue
                    hit = self._insert_consumed_scope(
                        cur, scope, scope_id, now, account_id, customer_id, subscription_id
                    )
                    if hit:
                        conflict = True
                        self._record_trial_conflict(
                            cur, "trial_scope_reuse", scope, scope_id, account_id,
                            customer_id, subscription_id,
                            "trialing subscription reused a consumed scope"
                        )
                cur.execute("COMMIT")
                return conflict
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
        return self._run(_do).result()

    def stripe_trial_invariants(self) -> list[dict]:
        def _do():
            rows = self._conn.execute(
                """SELECT 'customer_conflict' kind, stripe_customer_id scope_id, COUNT(*) count
                     FROM accounts WHERE stripe_customer_id IS NOT NULL
                 GROUP BY stripe_customer_id HAVING COUNT(*) > 1
                 UNION ALL
                   SELECT 'duplicate_trial_history', subscription_id, COUNT(*)
                     FROM stripe_trial_ledger
                    WHERE state='consumed' AND subscription_id IS NOT NULL
                 GROUP BY subscription_id HAVING COUNT(DISTINCT account_id) > 1"""
            ).fetchall()
            return [dict(r) for r in rows]
        return self._run(_do).result()

    def update_subscription(
        self,
        *,
        device_id: Optional[str] = None,
        customer_id: Optional[str] = None,
        subscription_id: Optional[str],
        status: Optional[str],
        renews_at: Optional[str],
    ) -> None:
        assert device_id or customer_id, "need device_id or customer_id"

        def _do() -> None:
            cur = self._conn.cursor()
            where = "device_id = ?" if device_id else "stripe_customer_id = ?"
            arg = device_id or customer_id
            plan = "pro" if status in ("active", "trialing", "past_due") else "free"
            cur.execute(
                f"""
                UPDATE users
                   SET plan = ?,
                       stripe_subscription_id = ?,
                       subscription_status = ?,
                       subscription_renews_at = ?,
                       updated_at = ?
                 WHERE {where}
                """,
                (plan, subscription_id, status, renews_at, _now_iso(), arg),
            )

        self._run(_do).result()

    # ---- accounts (Apple/Google sign-in) ----

    def upsert_account_by_provider(
        self,
        provider: str,
        sub: str,
        email: Optional[str] = None,
        *,
        link_into_account_id: Optional[str] = None,
    ) -> Account:
        """Find the account for this Apple/Google subject, creating one on
        first sign-in. Idempotent — signing in again with the same subject
        just returns the existing account (updating email if it changed).

        ``link_into_account_id`` is the calling device's *current* account
        (if it's already signed in) — pass it so that adding a second
        provider (e.g. "also let me sign in with Google") attaches to the
        SAME account instead of silently creating a stray second one. If
        that subject already belongs to a *different* account, raises
        AccountConflictError rather than merging two accounts that may
        each have their own history — merging is a decision a person
        should confirm explicitly, not something we do for them.
        """
        assert provider in ("apple", "google", "supabase"), f"unknown provider: {provider}"
        column = f"{provider}_sub"

        def _do() -> Account:
            cur = self._conn.cursor()
            cur.execute(f"SELECT * FROM accounts WHERE {column} = ?", (sub,))
            row = cur.fetchone()
            now = _now_iso()

            if row:
                if link_into_account_id and row["id"] != link_into_account_id:
                    raise AccountConflictError(
                        f"this {provider} identity is already linked to a different account"
                    )
                if email and email != row["email"]:
                    # Every caller of this path has already had the address
                    # proven by the provider (Apple/Google identity token, or
                    # a Supabase token whose email_verified claim was true —
                    # server.auth_web drops the address otherwise), so the
                    # verification stamp states a fact rather than assuming one.
                    cur.execute(
                        """UPDATE accounts
                              SET email = ?,
                                  email_normalized = ?,
                                  email_verified_at = COALESCE(email_verified_at, ?),
                                  updated_at = ?
                            WHERE id = ?""",
                        (email, normalize_email(email), now, now, row["id"]),
                    )
                    cur.execute("SELECT * FROM accounts WHERE id = ?", (row["id"],))
                    row = cur.fetchone()
                return _row_to_account(row)

            if link_into_account_id:
                # First time we've seen this identity, and the calling device
                # is already signed in — attach the provider to that account
                # (an upgrade, "add another way to sign in") instead of
                # minting a new one.
                cur.execute("SELECT * FROM accounts WHERE id = ?", (link_into_account_id,))
                existing = cur.fetchone()
                if not existing:
                    raise AccountConflictError(f"account {link_into_account_id} does not exist")
                # COALESCE on email so linking a second provider can never
                # overwrite an address the person already proved; the
                # verification stamp follows whichever address actually lands.
                cur.execute(
                    f"""UPDATE accounts
                           SET {column} = ?,
                               email = COALESCE(email, ?),
                               email_normalized = COALESCE(email_normalized, ?),
                               email_verified_at = CASE
                                   WHEN COALESCE(email, ?) IS NULL THEN email_verified_at
                                   ELSE COALESCE(email_verified_at, ?)
                               END,
                               updated_at = ?
                         WHERE id = ?""",
                    (
                        sub,
                        email,
                        normalize_email(email),
                        email,
                        now,
                        now,
                        link_into_account_id,
                    ),
                )
                cur.execute("SELECT * FROM accounts WHERE id = ?", (link_into_account_id,))
                return _row_to_account(cur.fetchone())

            account_id = str(uuid.uuid4())
            cur.execute(
                f"""INSERT INTO accounts
                        (id, {column}, email, email_normalized, email_verified_at,
                         plan, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'free', ?, ?)""",
                (
                    account_id,
                    sub,
                    email,
                    normalize_email(email),
                    now if email else None,
                    now,
                    now,
                ),
            )
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            return _row_to_account(cur.fetchone())

        return self._run(_do).result()

    def get_account(self, account_id: str) -> Optional[Account]:
        def _do() -> Optional[Account]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            row = cur.fetchone()
            return _row_to_account(row) if row else None

        return self._run(_do).result()

    # ------------------------------------------------------------------
    # Build 114 — email login identity
    #
    # Two tables, one purpose. `account_registrations` is the CURRENT product
    # state for a canonical account's email identity (the row a support
    # question or an admin screen reads). `account_registration_events` is the
    # append-only history of how it got there. Neither holds a password, a
    # verification/reset token, or a provider payload — Supabase owns those.
    #
    # `accounts.email` / `accounts.email_verified_at` remain the columns the
    # rest of the server already reads (entitlement routing, /v1/me, the
    # provider-linking primitive). The registration row does not duplicate
    # authority; it records the product lifecycle around it.
    # ------------------------------------------------------------------

    def begin_email_registration(
        self,
        *,
        account_id: str,
        email: str,
        source_surface: Optional[str] = None,
        app_version: Optional[str] = None,
        provider_subject: Optional[str] = None,
        pending_coupon_code: Optional[str] = None,
    ) -> Account:
        """Move `account_id` into the PENDING email-registration state.

        Writes only `email_normalized` on the account — never `email`, which
        stays reserved for a proven address (see `Account.is_identified`). So
        this call by itself opens nothing: the account remains unidentified and
        every private surface stays closed until `mark_email_verified` runs.

        Registering onto an account that already has a DIFFERENT verified
        address is refused, so a stray second registration cannot quietly
        re-point a live login identity at an attacker's address.

        ``provider_subject`` is the auth provider's own id for the user the
        signup just created. Recording it here is what makes "the anonymous
        device upgrades in place" true rather than aspirational: without it the
        only thing tying this registration to the eventual verification was the
        address, and the verification arrives on a completely different surface
        (a browser, from a mail app) with no bearer and no session — so the
        click minted a SECOND canonical account and the person's original one
        was orphaned, with its history, usage and purchase ownership on it.

        It is recorded on the REGISTRATION row, not on `accounts`, precisely so
        it changes nothing yet: writing it to `accounts.supabase_sub` would make
        `Account.is_identified` and `lifecycle_state` report a verified identity
        for an address nobody has proven. The claim is redeemed at proof time by
        `claim_pending_registration_account`.

        FIRST CLAIM WINS. A subject already claimed by a different account is
        left alone rather than re-pointed: a later caller must never be able to
        displace an earlier claimant and inherit the verification they are
        waiting for. The registration itself still proceeds — the fallback is
        simply the pre-existing behaviour for that device.
        """
        normalized = normalize_email(email)
        if not normalized:
            raise AccountConflictError("an email address is required")

        def _do() -> Account:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            row = cur.fetchone()
            if row is None:
                raise AccountConflictError(f"account {account_id} does not exist")
            existing = _row_to_account(row)
            if existing.deleted_at:
                raise AccountConflictError("account is no longer active")
            if existing.email_is_verified and existing.email_normalized != normalized:
                raise AccountConflictError(
                    "this account already has a verified email address"
                )
            now = _now_iso()
            cur.execute(
                "UPDATE accounts SET email_normalized = ?, updated_at = ? WHERE id = ?",
                (normalized, now, account_id),
            )
            claim = _clean_provider_subject(provider_subject)
            if claim is not None:
                cur.execute(
                    "SELECT account_id FROM account_registrations WHERE provider_subject = ?",
                    (claim,),
                )
                held = cur.fetchone()
                if held is not None and held["account_id"] != account_id:
                    claim = None  # first claim wins — see the docstring.
            self._upsert_registration_row(
                cur,
                account_id=account_id,
                lifecycle_state=email_identity.STATE_PENDING,
                email_normalized=normalized,
                source_surface=source_surface,
                app_build=app_version,
                now=now,
                provider_subject=claim,
            )
            if pending_coupon_code:
                cur.execute(
                    "UPDATE account_registrations SET pending_coupon_code = ? WHERE account_id = ?",
                    (pending_coupon_code.strip().upper(), account_id),
                )
            self._insert_registration_event(
                cur,
                account_id=account_id,
                event_type=email_identity.EVENT_SIGNUP_REQUESTED,
                source_surface=source_surface,
                app_build=app_version,
                now=now,
            )
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            return _row_to_account(cur.fetchone())

        return self._run(_do).result()

    def mark_email_verified(
        self,
        *,
        account_id: str,
        email: str,
        source_surface: Optional[str] = None,
        app_version: Optional[str] = None,
    ) -> Account:
        """Record proven ownership of `email` for this canonical account.

        This is the ONLY writer of `accounts.email` on the Build 114 email
        path, and it runs only after the auth provider has confirmed the
        address. It sets no plan and touches no subscription column. When the
        registration holds a pending coupon, this same transaction may redeem
        that coupon only after verification; otherwise a verified but
        unsubscribed person stays truthfully gated.

        The partial unique index on `account_registrations` makes "one verified
        address, one canonical account" a DATABASE invariant rather than a
        convention: a second account trying to verify the same address raises
        `AccountConflictError` instead of silently merging two histories.
        """
        normalized = normalize_email(email)
        if not normalized:
            raise AccountConflictError("an email address is required")

        def _do() -> Account:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            row = cur.fetchone()
            if row is None:
                raise AccountConflictError(f"account {account_id} does not exist")
            if _row_to_account(row).deleted_at:
                raise AccountConflictError("account is no longer active")
            # Explicit pre-check so the caller gets a domain error rather than
            # a raw IntegrityError, and so the conflict is auditable.
            cur.execute(
                """SELECT account_id FROM account_registrations
                    WHERE email_normalized = ?
                      AND lifecycle_state = ?
                      AND account_id <> ?""",
                (normalized, email_identity.STATE_VERIFIED, account_id),
            )
            clash = cur.fetchone()
            if clash is not None:
                self._insert_registration_event(
                    cur,
                    account_id=account_id,
                    event_type=email_identity.EVENT_IDENTITY_CONFLICT,
                    source_surface=source_surface,
                    app_build=app_version,
                    now=_now_iso(),
                    detail="verified_email_taken",
                )
                raise AccountConflictError(
                    "this email address already belongs to a different account"
                )
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                cur.execute(
                    """UPDATE accounts
                      SET email = ?,
                          email_normalized = ?,
                          email_verified_at = COALESCE(email_verified_at, ?),
                          updated_at = ?
                    WHERE id = ?""",
                    (normalized, normalized, now, now, account_id),
                )
                self._upsert_registration_row(
                    cur,
                    account_id=account_id,
                    lifecycle_state=email_identity.STATE_VERIFIED,
                    email_normalized=normalized,
                    source_surface=source_surface,
                    app_build=app_version,
                    now=now,
                    verified_at=now,
                    sign_in=True,
                )
                self._insert_registration_event(
                    cur,
                    account_id=account_id,
                    event_type=email_identity.EVENT_VERIFICATION_COMPLETED,
                    source_surface=source_surface,
                    app_build=app_version,
                    now=now,
                )
                cur.execute(
                    "SELECT pending_coupon_code FROM account_registrations WHERE account_id = ?",
                    (account_id,),
                )
                pending = cur.fetchone()
                if pending and pending["pending_coupon_code"]:
                    # Promo validity must never prevent verification or become
                    # an account/code enumeration side channel.
                    with contextlib.suppress(ValueError):
                        self._redeem_coupon_tx(cur, account_id, pending["pending_coupon_code"], now)
                    cur.execute(
                        "UPDATE account_registrations SET pending_coupon_code = NULL WHERE account_id = ?",
                        (account_id,),
                    )
                cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
                result = _row_to_account(cur.fetchone())
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def claim_pending_registration_account(self, provider_subject: str) -> Optional[str]:
        """Redeem the pre-verification claim for ``provider_subject``.

        Returns the canonical account id that STARTED a registration for this
        provider user, when that account is still eligible to receive it. This
        is the other half of `begin_email_registration`'s claim, and it is what
        makes the shipped verification sequence land on one person:

            anonymous account A  ->  register (A claims subject S)
              ->  the person opens the link in their mail app, which lands in a
                  BROWSER with no bearer and no session
              ->  the browser proves S  ->  this returns A  ->  A is upgraded

        Without it, that third step had nothing to resolve and minted a second
        canonical account; the person's real one — with their history, usage
        and any purchase ownership on it — was orphaned at the exact step the
        product's own UI instructs ("open the link, then come back and sign
        in").

        Eligibility is deliberately narrow. The claimant must still be a live,
        UNIDENTIFIED account: an account that has since acquired an identity of
        its own is a different person's, and a tombstoned one is not
        recoverable. A claim that fails either test is simply not redeemed, and
        the caller falls back to its ordinary resolution — never an error, and
        never a merge.
        """
        subject = _clean_provider_subject(provider_subject)
        if subject is None:
            return None

        def _do() -> Optional[str]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT a.*
                     FROM account_registrations r
                     JOIN accounts a ON a.id = r.account_id
                    WHERE r.provider_subject = ?""",
                (subject,),
            )
            row = cur.fetchone()
            if row is None:
                return None
            account = _row_to_account(row)
            if account.deleted_at or account.is_identified:
                return None
            return account.id

        return self._run(_do).result()

    def find_accounts_by_email(self, email: str) -> list[Account]:
        """Every live account whose normalized address matches.

        Returns a LIST, not one account, because a pending registration and a
        verified one can legitimately share an address spelling. No caller may
        treat this as "the" account for an address: it exists for collision
        detection and audit, never for resolving a login. Tombstoned accounts
        are excluded — a deleted account is not recoverable by email.
        """
        normalized = normalize_email(email)
        if not normalized:
            return []

        def _do() -> list[Account]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM accounts WHERE email_normalized = ? AND deleted_at IS NULL"
                " ORDER BY created_at",
                (normalized,),
            )
            return [_row_to_account(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def has_verified_email_account(self, email: str) -> bool:
        """True iff a non-tombstoned canonical account exists whose copy of this
        address is VERIFIED. This is the definition of an *existing Tono user*
        for magic-link login: the check runs against Tono's OWN ledger, so a
        magic-link request for an unknown address creates nothing on the shared
        provider (shouldCreateUser=false semantics) and the caller can answer the
        same anti-enumerating shape either way."""
        normalized = normalize_email(email)
        if not normalized:
            return False

        def _do() -> bool:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT 1 FROM accounts WHERE email_normalized = ? "
                "AND email_verified_at IS NOT NULL AND deleted_at IS NULL LIMIT 1",
                (normalized,),
            )
            return cur.fetchone() is not None

        return self._run(_do).result()

    def find_verified_email_account(
        self, provider: str, sub: str, email: Optional[str]
    ) -> Optional[str]:
        """The ONE canonical account this provider identity should join by a
        *verified* email, or ``None`` when there is no safe, unambiguous target.

        This is the account-continuity primitive. The same human signs in with
        Google on iOS (canonical key ``google:<google-sub>``) and later with
        Google on the website — where the browser authenticates through Supabase,
        so the web identity arrives as ``supabase:<supabase-uid>``, a *different*
        subject. Without a bridge the two never converge and the person owns two
        canonical accounts with split history and entitlements. Verified-email
        convergence is that bridge, and the contract permits it precisely because
        the address was proven by the provider on both surfaces.

        Deliberately conservative — it attaches, it never merges:

          * matches only accounts whose address is VERIFIED (``email_verified_at``
            set) and not tombstoned;
          * requires the ``{provider}_sub`` column to be EMPTY on the target, so
            we only ever *attach* this new identity to an account that does not
            yet own one of this kind — never rewrite a subject, never fuse two
            populated provider identities;
          * returns ``None`` when the address maps to more than one candidate.
            An ambiguous address (a shared or family mailbox that already spawned
            two accounts) must be resolved by an explicit, authenticated linking
            flow, not silently collapsed here where one account's history would
            be orphaned.

        The caller must have proven this address is verified for THIS identity
        (see ``server._resolve_provider_signin``'s ``email_verified`` gate); an
        unverified address can never reach this method with a non-null ``email``.
        """
        assert provider in ("apple", "google", "supabase"), f"unknown provider: {provider}"
        column = f"{provider}_sub"
        normalized = normalize_email(email)
        if not normalized:
            return None

        def _do() -> Optional[str]:
            cur = self._conn.cursor()
            cur.execute(
                f"""SELECT id FROM accounts
                     WHERE email_normalized = ?
                       AND email_verified_at IS NOT NULL
                       AND deleted_at IS NULL
                       AND ({column} IS NULL OR {column} = ?)""",
                (normalized, sub),
            )
            rows = cur.fetchall()
            if len(rows) != 1:
                # Zero: nothing to join. More than one: ambiguous — refuse to
                # pick, so no account's history is silently orphaned.
                return None
            return rows[0]["id"]

        return self._run(_do).result()

    def get_registration(self, account_id: str) -> Optional[dict]:
        """The current product registration row for one canonical account."""

        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM account_registrations WHERE account_id = ?", (account_id,)
            )
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()

    def record_registration_event(
        self,
        *,
        account_id: Optional[str],
        event_type: str,
        source_surface: Optional[str] = None,
        app_version: Optional[str] = None,
        detail: Optional[str] = None,
        attested: bool = True,
    ) -> None:
        """Append one audit event and advance the registration state.

        The event vocabulary is closed (`email_identity.EVENT_TYPES`) and the
        state machine is monotonic, so a replayed client event can never walk a
        verified registration back to pending.

        ``attested=False`` marks an event triggered by a caller that did not
        prove which account it was acting for — an unauthenticated resend or
        reset, which anyone can send for any address they can spell. The event
        is still recorded (it really happened), but the surface and build it
        claims are discarded rather than written onto someone else's row. See
        `_upsert_registration_row`.
        """

        def _do() -> None:
            cur = self._conn.cursor()
            now = _now_iso()
            if account_id:
                cur.execute(
                    "SELECT lifecycle_state FROM account_registrations WHERE account_id = ?",
                    (account_id,),
                )
                row = cur.fetchone()
                current = row["lifecycle_state"] if row else None
                resolved = email_identity.next_state(current, event_type)
                if row is not None or resolved != email_identity.STATE_PENDING:
                    self._upsert_registration_row(
                        cur,
                        account_id=account_id,
                        lifecycle_state=resolved,
                        email_normalized=None,
                        source_surface=source_surface,
                        app_build=app_version,
                        now=now,
                        sign_in=event_type == email_identity.EVENT_SIGN_IN,
                        attested=attested,
                    )
            self._insert_registration_event(
                cur,
                account_id=account_id,
                event_type=event_type,
                source_surface=source_surface,
                app_build=app_version,
                now=now,
                detail=detail,
                attested=attested,
            )

        self._run(_do).result()

    def _upsert_registration_row(
        self,
        cur: sqlite3.Cursor,
        *,
        account_id: str,
        lifecycle_state: str,
        email_normalized: Optional[str],
        source_surface: Optional[str],
        app_build: Optional[str],
        now: str,
        verified_at: Optional[str] = None,
        sign_in: bool = False,
        provider: str = "email",
        attested: bool = True,
        provider_subject: Optional[str] = None,
    ) -> None:
        """Create or advance the registration row.

        COALESCE everywhere it matters: an `email_normalized=None` update (an
        audit-only event) must not erase the address already recorded, and
        `created_at` / `verified_at` are stamped once and never rewritten.

        Two things this deliberately does NOT do, both of which it used to:

        * **`source_surface` is not last-writer-wins.** The column is named for
          where a registration STARTED, and a later event from another surface
          is not that fact. It used to be overwritten by any caller supplying
          something other than ``unknown``, so a registration begun on iOS and
          verified in a browser ended up reporting whichever surface wrote last
          — and `/admin/registrations` reported that as source. Once a real
          surface is recorded it is now immutable; recency lives in
          `last_seen_surface`, which is a different question with a different
          answer. `app_build` follows the same rule for the same reason.

        * **It does not accept unattested surface/build at all.** ``attested``
          is False for address-scoped events any unauthenticated caller can
          trigger for any address they can spell (resend, reset). Those callers
          supply `source_surface` / `app_version` in the request body, so
          honouring them let a stranger rewrite a stranger's audit fields.
          The EVENT is still recorded — something really did happen to this
          address — but it is recorded as unattributed, because an
          unauthenticated caller's claim about which app it is has no evidence
          behind it.
        """
        surface = email_identity.sanitize_source_surface(source_surface) if attested else None
        build = email_identity.sanitize_app_build(app_build) if attested else None
        cur.execute(
            """INSERT INTO account_registrations
                   (account_id, lifecycle_state, email_normalized, provider,
                    created_at, verified_at, source_surface, app_build,
                    last_seen_surface, last_seen_app_build,
                    last_sign_in_at, last_seen_at, updated_at, provider_subject)
               VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, ?), ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(account_id) DO UPDATE SET
                   provider_subject = COALESCE(account_registrations.provider_subject,
                                               excluded.provider_subject),
                   lifecycle_state = excluded.lifecycle_state,
                   email_normalized = COALESCE(excluded.email_normalized,
                                               account_registrations.email_normalized),
                   verified_at = COALESCE(account_registrations.verified_at,
                                          excluded.verified_at),
                   source_surface = CASE
                       WHEN account_registrations.source_surface <> ?
                           THEN account_registrations.source_surface
                       ELSE excluded.source_surface END,
                   app_build = COALESCE(account_registrations.app_build, excluded.app_build),
                   last_seen_surface = COALESCE(excluded.last_seen_surface,
                                                account_registrations.last_seen_surface),
                   last_seen_app_build = COALESCE(excluded.last_seen_app_build,
                                                  account_registrations.last_seen_app_build),
                   last_sign_in_at = COALESCE(excluded.last_sign_in_at,
                                              account_registrations.last_sign_in_at),
                   last_seen_at = excluded.last_seen_at,
                   updated_at = excluded.updated_at""",
            (
                account_id,
                lifecycle_state,
                email_normalized,
                provider,
                now,
                verified_at,
                surface,
                email_identity.SURFACE_UNKNOWN,
                build,
                surface,
                build,
                now if sign_in else None,
                now,
                now,
                _clean_provider_subject(provider_subject),
                email_identity.SURFACE_UNKNOWN,
            ),
        )

    def _insert_registration_event(
        self,
        cur: sqlite3.Cursor,
        *,
        account_id: Optional[str],
        event_type: str,
        source_surface: Optional[str],
        app_build: Optional[str],
        now: str,
        detail: Optional[str] = None,
        attested: bool = True,
    ) -> None:
        if event_type not in email_identity.EVENT_TYPES:
            raise ValueError(f"unknown registration event: {event_type}")
        # An unattested caller's surface/build claim is dropped here too, not
        # only on the state row. An append-only audit that records a stranger's
        # assertion as though it were observed is worse than one that records
        # `unknown`: the second is honest about what it does not know.
        cur.execute(
            """INSERT INTO account_registration_events
               (account_id, event_type, occurred_at, source_surface, app_build, detail)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                account_id,
                event_type,
                now,
                email_identity.sanitize_source_surface(source_surface if attested else None),
                email_identity.sanitize_app_build(app_build) if attested else None,
                detail,
            ),
        )

    def list_registration_events(self, account_id: str) -> list[dict]:
        """The auditable registration/verification history for one account,
        oldest first. Every row is timestamped and carries the surface and app
        build it came from; none carries a secret (see the table comment)."""

        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT id, account_id, event_type, occurred_at, source_surface,
                          app_build, detail
                     FROM account_registration_events
                    WHERE account_id = ?
                    ORDER BY occurred_at, id""",
                (account_id,),
            )
            return [dict(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def registration_metrics(self, *, days: int = 30) -> dict:
        """Aggregate registration reporting — counts only, never rows.

        This is the third leg of the Build 114 brief ("Tono tracks
        registrations"). ``list_registration_events`` answers "what happened to
        MY account" for one signed-in person; this answers "how is registration
        going" for whoever runs the product, and the two must not be the same
        query. An operator does not need to know who registered, and this
        method is written so it could not tell them if they asked:

          * it selects only ``COUNT(*)`` and the grouping column, so no
            ``account_id``, ``email_normalized`` or ``detail`` value can be in
            the result at all — the PII-minimization is structural, not a
            filter someone can forget to apply;
          * every grouping column is one the store itself sanitized on write
            (``lifecycle_state`` is CHECK-constrained, ``source_surface`` is
            clamped to the known set, ``app_build`` is charset- and
            length-bounded), so nothing client-shaped is echoed back either.

        ``days`` bounds the event histogram and the "new in window" counts. The
        state totals are deliberately NOT windowed: "how many verified accounts
        exist" is a stock, and answering it for the last 30 days only would
        quietly under-report every account that registered before then.
        """
        window_days = max(1, min(int(days), 365))
        cutoff = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=window_days)
        ).isoformat(timespec="seconds")

        def _do() -> dict:
            cur = self._conn.cursor()

            def _histogram(sql: str, params: tuple = ()) -> dict:
                cur.execute(sql, params)
                # `key` may be NULL (an event written with no build tag). It is
                # reported as "unknown" rather than dropped: a registration we
                # cannot attribute to a build is still a registration.
                return {
                    (row["key"] if row["key"] is not None else "unknown"): row["cnt"]
                    for row in cur.fetchall()
                }

            by_state = _histogram(
                "SELECT lifecycle_state AS key, COUNT(*) AS cnt "
                "FROM account_registrations GROUP BY lifecycle_state"
            )
            by_surface = _histogram(
                "SELECT source_surface AS key, COUNT(*) AS cnt "
                "FROM account_registrations GROUP BY source_surface"
            )
            by_build = _histogram(
                "SELECT app_build AS key, COUNT(*) AS cnt "
                "FROM account_registrations GROUP BY app_build"
            )
            events = _histogram(
                "SELECT event_type AS key, COUNT(*) AS cnt "
                "FROM account_registration_events WHERE occurred_at >= ? "
                "GROUP BY event_type",
                (cutoff,),
            )

            cur.execute(
                "SELECT COUNT(*) AS cnt FROM account_registrations WHERE created_at >= ?",
                (cutoff,),
            )
            created_in_window = cur.fetchone()["cnt"]
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM account_registrations WHERE verified_at >= ?",
                (cutoff,),
            )
            verified_in_window = cur.fetchone()["cnt"]
            cur.execute(
                "SELECT COUNT(*) AS cnt FROM account_registrations WHERE last_sign_in_at >= ?",
                (cutoff,),
            )
            signed_in_in_window = cur.fetchone()["cnt"]

            return {
                "days": window_days,
                "registrations_total": sum(by_state.values()),
                "by_lifecycle_state": by_state,
                "by_source_surface": by_surface,
                "by_app_build": by_build,
                "created_in_window": created_in_window,
                "verified_in_window": verified_in_window,
                "signed_in_in_window": signed_in_in_window,
                "events_in_window": events,
            }

        return self._run(_do).result()

    def sign_out_device(self, device_id: str) -> bool:
        """Detach ONE device from whatever account it is signed into.

        Why rotating the bearer is not enough. A device keeps a durable
        ``device_credential`` precisely so it can re-register itself under the
        same ``device_id`` after losing its token. That is right for a reinstall
        and wrong for a sign-out: a rotated bearer plus a live credential means
        the very next ``/v1/register`` hands the device a fresh token for a row
        that is still linked to the account. On a shared device that is not a
        sign-out at all — the next person's app silently signs back in.

        So this does all three things a sign-out actually means:

          1. rotates ``api_token`` and voids the previous-token grace, so every
             bearer that existed a moment ago is dead;
          2. nulls ``device_credential_hash``, so the device cannot prove itself
             back into this row;
          3. unlinks the row from the account.

        What it deliberately does NOT do is touch the account. The canonical
        UUID, the history, the entitlement and the registration audit all
        survive untouched — signing back in converges on the identical person
        (see ``server._resolve_provider_signin``). Sign-out is a device-scoped
        act; deletion is the account-scoped one, and they must not be confused.

        Leaving ``account_id`` NULL is safe: ``ensure_account`` mints a fresh
        anonymous account for the device the next time it is seen, which is the
        truthful state for a signed-out device.

        Two things this also does, both because the row is now RETIRED rather
        than merely detached:

        * It stamps ``signed_out_at``. Nulling the credential and rotating the
          token means nothing can ever prove itself back into this row, so
          ``register_device`` could satisfy neither its credential nor its
          legacy-bearer proof and answered a permanent 409 for that device id.
          The stamp is what lets it re-issue the slot as a brand-new device
          instead (see `register_device`), which is what a person reinstalling
          on the same handset actually experiences.
        * It clears the device row's own plan/subscription/coupon copies. Those
          columns are the anonymous-era entitlement mirror, and after sign-out
          this row belongs to nobody; leaving a stale ``plan='pro'`` on a slot
          that can be re-registered would hand the next claimant an entitlement
          they never bought. The ACCOUNT's entitlement is untouched — it lives
          on `accounts`, which this does not write.

        Returns True when a device row was actually signed out.
        """

        def _do() -> bool:
            cur = self._conn.cursor()
            cur.execute("BEGIN IMMEDIATE")
            try:
                cur.execute(
                    """UPDATE users
                          SET api_token = ?,
                              previous_api_token = NULL,
                              previous_api_token_expires_at = NULL,
                              device_credential_hash = NULL,
                              account_id = NULL,
                              signed_out_at = ?,
                              plan = 'free',
                              stripe_subscription_id = NULL,
                              subscription_status = NULL,
                              subscription_renews_at = NULL,
                              coupon_pro_expires_at = NULL,
                              updated_at = ?
                        WHERE device_id = ?""",
                    (_new_token(), _now_iso(), _now_iso(), device_id),
                )
                changed = cur.rowcount
                cur.execute("COMMIT")
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
            return bool(changed)

        return self._run(_do).result()

    def delete_account(self, account_id: str) -> dict:
        """Delete a person's account: revoke every session/device, drop private
        identity data, and TOMBSTONE the account row rather than deleting it.

        Why tombstone instead of DELETE: append-only billing/provider audit
        facts (entitlement_grants, stripe_events, and the account's own Stripe
        customer/subscription ids) reference this account id and must remain
        valid for legal/accounting reasons. So we keep the row (and its Stripe
        ids) but clear every identity/private column and stamp ``deleted_at``.
        After this, ``is_identified`` is false, so the account can never again
        be resolved by a provider subject or drive Pro entitlement by identity.

        Revocation is real: for every linked device we mint a fresh random
        api_token the caller never learns, void any previous-token grace, and
        null the device credential hash — so every bearer that existed before
        deletion (and any recovery proof) stops working immediately.

        Returns a summary dict for the caller/tests. Idempotent-ish: deleting
        an already-tombstoned account revokes nothing new and reports 0."""

        def _do() -> dict:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            row = cur.fetchone()
            if row is None:
                return {"deleted": False, "revoked_devices": 0}
            now = _now_iso()

            cur.execute("BEGIN IMMEDIATE")
            try:
                # 1) Revoke every device linked to this account.
                cur.execute(
                    "SELECT device_id FROM users WHERE account_id = ?", (account_id,)
                )
                device_ids = [r["device_id"] for r in cur.fetchall()]
                for did in device_ids:
                    cur.execute(
                        """UPDATE users
                              SET api_token = ?,
                                  previous_api_token = NULL,
                                  previous_api_token_expires_at = NULL,
                                  device_credential_hash = NULL,
                                  updated_at = ?
                            WHERE device_id = ?""",
                        (_new_token(), now, did),
                    )

                # 2) Drop private identity data (passkeys) tied to the account.
                cur.execute(
                    "DELETE FROM webauthn_credentials WHERE account_id = ?", (account_id,)
                )

                # 3) Tombstone: clear identity/contact columns, keep the row and
                #    its Stripe billing ids (append-only audit), stamp deleted_at.
                cur.execute(
                    """UPDATE accounts
                          SET apple_sub = NULL,
                              google_sub = NULL,
                              supabase_sub = NULL,
                              email = NULL,
                              email_normalized = NULL,
                              email_verified_at = NULL,
                              deleted_at = ?,
                              updated_at = ?
                        WHERE id = ?""",
                    (now, now, account_id),
                )

                # 4) Tombstone the Build 114 registration row too, and RELEASE
                #    the address it was holding.
                #
                #    Step 3 clears `accounts.email_normalized`, but the
                #    registration row is a second place the address lives, and
                #    leaving it at `verified` keeps the partial unique index
                #    claiming the mailbox on behalf of an account that no
                #    longer exists. The person who deleted their account and
                #    then signs up again with the same address resolves to a
                #    NEW canonical account (their old provider subject was
                #    cleared above), and `mark_email_verified` would refuse it
                #    as "already belongs to a different account" — locking them
                #    out of their own mailbox permanently.
                #
                #    Deletion is meant to be terminal for the DATA, not a
                #    permanent reservation of the address. The audit row itself
                #    survives (state, timestamps, surface) and so does the
                #    append-only event stream, which by design carries no
                #    address — so releasing the identifier costs no auditability.
                cur.execute(
                    """UPDATE account_registrations
                          SET lifecycle_state = ?,
                              email_normalized = NULL,
                              updated_at = ?
                        WHERE account_id = ?""",
                    (email_identity.STATE_DISABLED, now, account_id),
                )
                cur.execute("COMMIT")
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
            return {"deleted": True, "revoked_devices": len(device_ids)}

        return self._run(_do).result()

    def link_device_to_account(self, device_id: str, account_id: str) -> None:
        """Attach this device to an account. Safe to call repeatedly (e.g.
        re-signing-in on the same device) and safe to call from multiple
        devices for the same account — that's the whole point: every linked
        device shares the account's Pro status from then on."""

        def _do() -> None:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                # Converge bounded anonymous/device legacy coupon facts before
                # switching principals. This never increments coupons.use_count:
                # legacy redemption already did that when originally consumed.
                cur.execute(
                    "SELECT account_id, coupon_pro_expires_at FROM users WHERE device_id = ?",
                    (device_id,),
                )
                legacy = cur.fetchone()
                if legacy and legacy["coupon_pro_expires_at"] and legacy["coupon_pro_expires_at"] > now:
                    cur.execute(
                        """UPDATE accounts SET coupon_pro_expires_at =
                               CASE WHEN coupon_pro_expires_at IS NULL
                                          OR coupon_pro_expires_at < ?
                                    THEN ? ELSE coupon_pro_expires_at END,
                               updated_at = ?
                             WHERE id = ?""",
                        (legacy["coupon_pro_expires_at"], legacy["coupon_pro_expires_at"], now, account_id),
                    )
                    cur.execute(
                        """INSERT OR IGNORE INTO account_coupon_redemptions
                               (account_id, code, redeemed_at, expires_at)
                           SELECT ?, r.code, r.redeemed_at, ?
                             FROM coupon_redemptions r WHERE r.device_id = ?""",
                        (account_id, legacy["coupon_pro_expires_at"], device_id),
                    )
                cur.execute(
                    "UPDATE users SET account_id = ?, updated_at = ? WHERE device_id = ?",
                    (account_id, now, device_id),
                )
                cur.execute("COMMIT")
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        self._run(_do).result()

    def update_account_subscription(
        self,
        *,
        account_id: Optional[str] = None,
        customer_id: Optional[str] = None,
        subscription_id: Optional[str],
        status: Optional[str],
        renews_at: Optional[str],
    ) -> None:
        """Account-level counterpart of `update_subscription` — what
        apps/backend/Backend/payments.py's webhook handler calls when a
        subscription is tied to a signed-in account, so it covers every
        device linked to that account rather than just the one that
        started checkout. Falls back to `customer_id` lookup the same way
        the device-level method does, for webhook events that don't carry
        our metadata (e.g. a Billing Portal-initiated cancellation)."""
        assert account_id or customer_id, "need account_id or customer_id"

        def _do() -> None:
            cur = self._conn.cursor()
            where = "id = ?" if account_id else "stripe_customer_id = ?"
            arg = account_id or customer_id
            plan = "pro" if status in ("active", "trialing", "past_due") else "free"
            cur.execute(
                f"""
                UPDATE accounts
                   SET plan = ?,
                       stripe_subscription_id = ?,
                       subscription_status = ?,
                       subscription_renews_at = ?,
                       updated_at = ?
                 WHERE {where}
                """,
                (plan, subscription_id, status, renews_at, _now_iso(), arg),
            )

        self._run(_do).result()

    # ---- passkeys (WebAuthn) ----

    def create_bare_account(self) -> Account:
        """A brand-new account with no Apple/Google identity — passkey
        registration can be someone's *first* sign-up, not just an addition
        to an existing Apple/Google account."""

        def _do() -> Account:
            cur = self._conn.cursor()
            account_id = str(uuid.uuid4())
            now = _now_iso()
            cur.execute(
                "INSERT INTO accounts (id, plan, created_at, updated_at) VALUES (?, 'free', ?, ?)",
                (account_id, now, now),
            )
            cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
            return _row_to_account(cur.fetchone())

        return self._run(_do).result()

    def add_webauthn_credential(
        self,
        *,
        credential_id: str,
        account_id: str,
        public_key: bytes,
        sign_count: int,
        transports: Optional[list[str]] = None,
        nickname: Optional[str] = None,
    ) -> None:
        def _do() -> None:
            self._conn.execute(
                """INSERT INTO webauthn_credentials
                       (credential_id, account_id, public_key, sign_count, transports, nickname, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    credential_id,
                    account_id,
                    public_key,
                    sign_count,
                    json.dumps(transports or []),
                    nickname,
                    _now_iso(),
                ),
            )

        self._run(_do).result()

    def get_webauthn_credential(self, credential_id: str) -> Optional[WebAuthnCredential]:
        def _do() -> Optional[WebAuthnCredential]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM webauthn_credentials WHERE credential_id = ?", (credential_id,))
            row = cur.fetchone()
            return _row_to_webauthn_credential(row) if row else None

        return self._run(_do).result()

    def list_webauthn_credentials(self, account_id: str) -> list[WebAuthnCredential]:
        def _do() -> list[WebAuthnCredential]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM webauthn_credentials WHERE account_id = ? ORDER BY created_at", (account_id,)
            )
            return [_row_to_webauthn_credential(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def update_webauthn_sign_count(self, credential_id: str, new_count: int) -> None:
        def _do() -> None:
            self._conn.execute(
                "UPDATE webauthn_credentials SET sign_count = ?, last_used_at = ? WHERE credential_id = ?",
                (new_count, _now_iso(), credential_id),
            )

        self._run(_do).result()

    def delete_webauthn_credential(self, credential_id: str, account_id: str) -> bool:
        """Scoped to account_id so one account can't delete another's
        credential by guessing/enumerating credential_id values."""

        def _do() -> bool:
            cur = self._conn.execute(
                "DELETE FROM webauthn_credentials WHERE credential_id = ? AND account_id = ?",
                (credential_id, account_id),
            )
            return cur.rowcount > 0

        return self._run(_do).result()

    # ---- rewrite telemetry (NON-authorizing) ----

    def record_rewrite(self, device_id: str) -> int:
        """Advance the per-day rewrite telemetry counter and return the running
        count for today (post-increment).

        This method is **non-authorizing**. Under the commercial contract there
        is NO free daily tier: the sole rewrite gate is the shared
        server-authoritative entitlement projection (``User.is_pro``, enforced by
        ``server._require_rewrite_entitlement`` before any provider call). Every
        caller that reaches here has already passed that gate, so this counter
        never grants, never denies, and never reads ``FREE_DAILY_LIMIT`` — it
        exists only for the ``used_today`` disclosure and abuse metering.

        The counter pools on the account once the device is IDENTIFIED (signed
        in) and otherwise counts per-device, matching the historical quota
        anchoring. `table`/`key_col` are fixed internal literals (never user
        input), picking which row the counter lives on.
        """

        def _do() -> int:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT daily_count, daily_day, account_id FROM users WHERE device_id = ?",
                (device_id,),
            )
            row = cur.fetchone()
            if not row:
                return 0

            account_row = None
            if row["account_id"]:
                cur.execute("SELECT * FROM accounts WHERE id = ?", (row["account_id"],))
                account_row = cur.fetchone()
            identified = bool(
                account_row
                and (account_row["apple_sub"] or account_row["google_sub"] or account_row["email"])
            )
            if identified:
                quota_row = account_row
                table, key_col, key_val = "accounts", "id", row["account_id"]
            else:
                quota_row = row
                table, key_col, key_val = "users", "device_id", device_id

            today = _today_utc()
            cur.execute("BEGIN IMMEDIATE")
            try:
                if quota_row["daily_day"] != today:
                    cur.execute(
                        f"UPDATE {table} SET daily_count=1, daily_day=?, updated_at=? WHERE {key_col}=?",
                        (today, _now_iso(), key_val),
                    )
                    used = 1
                else:
                    cur.execute(
                        f"UPDATE {table} SET daily_count=daily_count+1, updated_at=? WHERE {key_col}=?",
                        (_now_iso(), key_val),
                    )
                    used = (quota_row["daily_count"] or 0) + 1
                cur.execute("COMMIT")
            except Exception:
                cur.execute("ROLLBACK")
                raise
            return used

        return self._run(_do).result()

    # ---- response cache ----

    def get_cached_response(self, cache_key: str, ttl_seconds: int = 300) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT response_json, created_at FROM response_cache WHERE cache_key = ?",
                (cache_key,),
            )
            row = cur.fetchone()
            if not row:
                return None
            age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(row["created_at"])).total_seconds()
            if age > ttl_seconds:
                cur.execute("DELETE FROM response_cache WHERE cache_key = ?", (cache_key,))
                return None
            return json.loads(row["response_json"])

        return self._run(_do).result()

    def set_cached_response(self, cache_key: str, response: dict) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT OR REPLACE INTO response_cache (cache_key, response_json, created_at) VALUES (?, ?, ?)",
                (cache_key, json.dumps(response), _now_iso()),
            )

        self._executor.submit(_do)

    def purge_expired_cache(self, ttl_seconds: int = 300) -> None:
        def _do() -> None:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=ttl_seconds)
            ).isoformat(timespec="seconds")
            self._conn.execute(
                "DELETE FROM response_cache WHERE created_at < ?", (cutoff,)
            )

        self._executor.submit(_do)

    # ---- axis events ----

    def log_axis_event(self, device_id: str, axis: str, risk_level: str) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT INTO axis_events (device_id, ts, axis, risk_level) VALUES (?, ?, ?, ?)",
                (device_id, _now_iso(), axis, risk_level),
            )

        self._executor.submit(_do)

    def axis_stats(self, days: int = 30) -> dict:
        """Aggregate axis tap counts for the last N days."""
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                "SELECT axis, COUNT(*) as cnt FROM axis_events WHERE ts >= ? GROUP BY axis ORDER BY cnt DESC",
                (cutoff,),
            )
            return {row["axis"]: row["cnt"] for row in cur.fetchall()}

        return self._run(_do).result()

    def axis_stats_by_risk(self, days: int = 30) -> dict:
        """Axis tap counts broken down by risk level for the last N days.

        Returns ``{risk_level: {axis: count}}``. Used to understand which
        axes resonate when messages are high-risk vs low-risk — feeds into
        prompt ordering when no per-user preference exists.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT risk_level, axis, COUNT(*) as cnt
                   FROM axis_events WHERE ts >= ?
                   GROUP BY risk_level, axis
                   ORDER BY risk_level, cnt DESC""",
                (cutoff,),
            )
            result: dict = {}
            for row in cur.fetchall():
                rl = row["risk_level"]
                if rl not in result:
                    result[rl] = {}
                result[rl][row["axis"]] = row["cnt"]
            return result

        return self._run(_do).result()

    def global_axis_ranking(self, days: int = 30) -> list:
        """Return all four axes sorted by global win count (most-chosen first).

        Used as the collective-intelligence default when a client has no
        per-user StyleMemory preference yet. Falls back to the canonical
        default order when the DB has no axis events.
        """
        _default = ["warmer", "clearer", "funnier", "safer"]
        stats = self.axis_stats(days=days)
        if not stats:
            return _default
        return sorted(_default, key=lambda a: stats.get(a, 0), reverse=True)

    # ---- collective improvement events ----

    def log_improvement_event(
        self,
        device_id: str,
        risk_predicted: str,
        axis_selected: "Optional[str]",
        mode: str,
        msg_len_bucket: str,
        rewrite_used: bool,
        edit_after: bool = False,
    ) -> None:
        """Store one content-free behavioral outcome for the collective signal.

        Called only when the 'improve_tono' flag is enabled for the device.
        device_id is retained solely to enforce the k-anonymity floor at
        aggregation time; individual rows are never queried outside of bulk
        aggregates.
        """
        def _do() -> None:
            self._conn.execute(
                """INSERT INTO improvement_events
                   (device_id, ts, risk_predicted, axis_selected, mode,
                    msg_len_bucket, rewrite_used, edit_after)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    device_id, _now_iso(), risk_predicted, axis_selected, mode,
                    msg_len_bucket, int(rewrite_used), int(edit_after),
                ),
            )
        self._executor.submit(_do)

    def get_axis_effectiveness(
        self,
        days: int = 30,
        min_devices: int = 50,
    ) -> dict:
        """Axis win rates by risk level.

        k-anonymity: only returns patterns backed by >= min_devices distinct
        devices. This is enforced at the SQL level with HAVING, not by
        convention — a pattern with fewer contributors is discarded entirely.

        Returns ``{risk_level: [{axis, events, distinct_devices}, ...]}``.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT risk_predicted, axis_selected,
                          COUNT(*) AS event_count,
                          COUNT(DISTINCT device_id) AS device_count
                   FROM improvement_events
                   WHERE ts >= ? AND rewrite_used = 1 AND axis_selected IS NOT NULL
                   GROUP BY risk_predicted, axis_selected
                   HAVING COUNT(DISTINCT device_id) >= ?
                   ORDER BY risk_predicted, event_count DESC""",
                (cutoff, min_devices),
            )
            result: dict = {}
            for row in cur.fetchall():
                rp = row["risk_predicted"]
                if rp not in result:
                    result[rp] = []
                result[rp].append({
                    "axis": row["axis_selected"],
                    "events": row["event_count"],
                    "distinct_devices": row["device_count"],
                })
            return result
        return self._run(_do).result()

    def get_rewrite_quality(
        self,
        days: int = 30,
        min_devices: int = 50,
    ) -> dict:
        """Edit-after-insert rate by axis — a proxy for rewrite quality.

        High edit_after_rate = users are choosing the axis but rewriting the
        suggestion, meaning the rewrite is close-but-wrong. Feed this into
        prompt revision for those axes.

        k-anonymity: same HAVING floor as get_axis_effectiveness.

        Returns ``{axis: {total_insertions, edit_after_count, edit_after_rate,
        distinct_devices}}``.
        """
        def _do() -> dict:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                """SELECT axis_selected,
                          COUNT(*) AS total,
                          SUM(edit_after) AS edits,
                          COUNT(DISTINCT device_id) AS device_count
                   FROM improvement_events
                   WHERE ts >= ? AND rewrite_used = 1 AND axis_selected IS NOT NULL
                   GROUP BY axis_selected
                   HAVING COUNT(DISTINCT device_id) >= ?
                   ORDER BY axis_selected""",
                (cutoff, min_devices),
            )
            result: dict = {}
            for row in cur.fetchall():
                total = row["total"]
                edits = row["edits"] or 0
                result[row["axis_selected"]] = {
                    "total_insertions": total,
                    "edit_after_count": edits,
                    "edit_after_rate": round(edits / total, 3) if total > 0 else 0.0,
                    "distinct_devices": row["device_count"],
                }
            return result
        return self._run(_do).result()

    def age_out_improvement_events(self, retain_days: int = 90) -> int:
        """Delete improvement_events older than retain_days. Returns count deleted.

        Raw events are kept only long enough to compute rolling aggregates;
        after that they are discarded. Call periodically (e.g. nightly).
        """
        def _do() -> int:
            cutoff = (
                dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=retain_days)
            ).strftime("%Y-%m-%d")
            cur = self._conn.cursor()
            cur.execute(
                "DELETE FROM improvement_events WHERE ts < ?", (cutoff,)
            )
            return cur.rowcount
        return self._run(_do).result()

    # ---- Slack ----

    def upsert_slack_workspace(
        self, team_id: str, access_token: str, team_name: str, bot_user_id: str
    ) -> None:
        now = _now_iso()
        def _do() -> None:
            self._conn.execute(
                """
                INSERT INTO slack_workspaces (team_id, access_token, team_name, bot_user_id, installed_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(team_id) DO UPDATE SET
                    access_token = excluded.access_token,
                    team_name    = excluded.team_name,
                    bot_user_id  = excluded.bot_user_id,
                    updated_at   = excluded.updated_at
                """,
                (team_id, access_token, team_name, bot_user_id, now, now),
            )

        self._run(_do).result()

    # ---- coupons ----

    def _redeem_coupon_tx(
        self, cur: sqlite3.Cursor, account_id: str, code: str, now: str,
        device_id: Optional[str] = None,
    ) -> str:
        cur.execute("SELECT * FROM accounts WHERE id = ?", (account_id,))
        account = cur.fetchone()
        if not account:
            raise ValueError("Sign in to a verified account before redeeming a code.")
        cur.execute("SELECT * FROM coupons WHERE code = ?", (code,))
        row = cur.fetchone()
        if not row:
            raise ValueError("Invalid code.")
        # Identity gate. Normal coupons require an identified account (unchanged
        # ownership). A coupon explicitly flagged ``anonymous_eligible`` (Build
        # 117 app-review compatibility) may also be redeemed by an UNIDENTIFIED
        # canonical account. This is opt-in per coupon — never a universal
        # anonymous promo — and the grant still binds to THIS account UUID only.
        is_identified = _row_to_account(account).is_identified
        if not is_identified and not row["anonymous_eligible"]:
            raise ValueError("Sign in to a verified account before redeeming a code.")
        if row["expires_at"] and row["expires_at"] < now:
            raise ValueError("This code has expired.")
        cur.execute(
            "SELECT 1 FROM account_coupon_redemptions WHERE account_id = ? AND code = ?",
            (account_id, code),
        )
        if cur.fetchone():
            raise ValueError("You've already redeemed this code.")
        if row["max_uses"] > 0 and row["use_count"] >= row["max_uses"]:
            raise ValueError("This code has reached its usage limit.")
        now_dt = dt.datetime.fromisoformat(now)
        current = account["coupon_pro_expires_at"]
        base = now_dt
        if current:
            with contextlib.suppress(ValueError):
                parsed = dt.datetime.fromisoformat(current)
                if parsed > base:
                    base = parsed
        expires_at = (base + dt.timedelta(days=int(row["duration_days"]))).isoformat(timespec="seconds")
        cur.execute(
            """INSERT INTO account_coupon_redemptions
                   (account_id, code, redeemed_at, expires_at) VALUES (?, ?, ?, ?)""",
            (account_id, code, now, expires_at),
        )
        cur.execute(
            """UPDATE coupons SET use_count = use_count + 1
                 WHERE code = ? AND (max_uses = 0 OR use_count < max_uses)""",
            (code,),
        )
        if cur.rowcount != 1:
            raise ValueError("This code has reached its usage limit.")
        cur.execute(
            "UPDATE accounts SET coupon_pro_expires_at = ?, updated_at = ? WHERE id = ?",
            (expires_at, now, account_id),
        )
        # Anonymous redemption only: project the grant onto the redeeming device
        # row so the anonymous User.is_pro path — which reads the device's own
        # coupon field, not the account's — resolves to Pro. An identified
        # account reads entitlement from the account, so this device projection
        # is applied ONLY when the account is not identified and stays scoped to
        # the exact (device_id, account_id) pair (no cross-device leakage).
        if not is_identified and device_id:
            cur.execute(
                "UPDATE users SET coupon_pro_expires_at = ? "
                "WHERE device_id = ? AND account_id = ?",
                (expires_at, device_id, account_id),
            )
        return expires_at

    def redeem_coupon(self, account_id: str, code: str, device_id: Optional[str] = None) -> str:
        """Redeem a coupon code for the canonical account. Returns the new
        coupon_pro_expires_at ISO string on success.
        Raises ValueError with a user-visible message on failure."""
        def _do() -> str:
            now = _now_iso()
            cur = self._conn.cursor()
            cur.execute("BEGIN IMMEDIATE")
            try:
                expires_at = self._redeem_coupon_tx(cur, account_id, code, now, device_id)
                cur.execute("COMMIT")
            except Exception:
                cur.execute("ROLLBACK")
                raise
            return expires_at

        return self._run(_do).result()

    def coupon_allows_anonymous(self, code: str) -> bool:
        """True iff a coupon with this code EXISTS and is flagged
        anonymous_eligible. Used by the redeem endpoint to decide whether an
        unidentified account may proceed (defense in depth with the redemption
        transaction, which enforces the same rule). A non-existent code is False
        — an anonymous caller never learns a code exists by probing."""
        def _do() -> bool:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT anonymous_eligible FROM coupons WHERE code = ?", (code,)
            )
            row = cur.fetchone()
            return bool(row and row["anonymous_eligible"])

        return self._run(_do).result()

    def create_coupon(
        self,
        code: str,
        duration_days: int,
        max_uses: int = 0,
        expires_at: Optional[str] = None,
        anonymous_eligible: bool = False,
    ) -> bool:
        """Insert a new coupon. Returns False if the code already exists.

        ``anonymous_eligible`` (default False) opts a single code into
        redemption by an unidentified account (Build 117 app review). Pair it
        with a small ``max_uses`` and a near ``expires_at`` to bound exposure."""
        def _do() -> bool:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    """
                    INSERT INTO coupons (code, duration_days, max_uses, use_count, created_at, expires_at, anonymous_eligible)
                    VALUES (?, ?, ?, 0, ?, ?, ?)
                    """,
                    (code, duration_days, max_uses, _now_iso(), expires_at,
                     1 if anonymous_eligible else 0),
                )
                return True
            except sqlite3.IntegrityError:
                return False

        return self._run(_do).result()

    def get_slack_workspace(self, team_id: str) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM slack_workspaces WHERE team_id = ?", (team_id,))
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()

    # ---- audit ----

    def log_usage(
        self,
        device_id: str,
        endpoint: str,
        status_code: int,
        provider: Optional[str] = None,
        drafts_chars: Optional[int] = None,
    ) -> None:
        def _do() -> None:
            self._conn.execute(
                "INSERT INTO usage_log (device_id, ts, endpoint, status_code, provider, drafts_chars) VALUES (?, ?, ?, ?, ?, ?)",
                (device_id, _now_iso(), endpoint, status_code, provider, drafts_chars),
            )

        self._executor.submit(_do)

    # ---- feature flags ----

    def get_features(self, device_id: str, is_pro: bool) -> dict[str, bool]:
        """Resolve flags for a device: global default → plan gate → user override."""
        def _do() -> dict[str, bool]:
            cur = self._conn.cursor()
            cur.execute("SELECT key, enabled, plan_required FROM feature_flags")
            flags = {row["key"]: {"enabled": bool(row["enabled"]), "plan": row["plan_required"]}
                     for row in cur.fetchall()}
            cur.execute(
                "SELECT flag_key, enabled FROM user_feature_overrides WHERE device_id = ?",
                (device_id,),
            )
            overrides = {row["flag_key"]: bool(row["enabled"]) for row in cur.fetchall()}
            result: dict[str, bool] = {}
            for key, meta in flags.items():
                if meta["plan"] == "pro" and not is_pro:
                    result[key] = False
                    continue
                result[key] = overrides.get(key, meta["enabled"])
            return result

        return self._run(_do).result()

    def get_all_flags(self) -> list[dict]:
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM feature_flags ORDER BY key")
            return [dict(row) for row in cur.fetchall()]

        return self._run(_do).result()

    def update_flag(
        self,
        key: str,
        enabled: Optional[bool] = None,
        plan_required: Optional[str] = "UNCHANGED",
        rollout_pct: Optional[int] = None,
    ) -> bool:
        def _do() -> bool:
            sets, params = [], []
            if enabled is not None:
                sets.append("enabled = ?")
                params.append(int(enabled))
            if plan_required != "UNCHANGED":
                sets.append("plan_required = ?")
                params.append(plan_required)
            if rollout_pct is not None:
                sets.append("rollout_pct = ?")
                params.append(rollout_pct)
            if not sets:
                return True
            sets.append("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")
            params.append(key)
            cur = self._conn.cursor()
            cur.execute(f"UPDATE feature_flags SET {', '.join(sets)} WHERE key = ?", params)
            return cur.rowcount > 0

        return self._run(_do).result()

    def set_user_flag_override(
        self, device_id: str, flag_key: str, enabled: bool, set_by: str = "admin"
    ) -> None:
        def _do() -> None:
            self._conn.execute(
                """INSERT OR REPLACE INTO user_feature_overrides
                   (device_id, flag_key, enabled, set_by)
                   VALUES (?, ?, ?, ?)""",
                (device_id, flag_key, int(enabled), set_by),
            )

        self._run(_do).result()

    def delete_user_flag_override(self, device_id: str, flag_key: str) -> None:
        def _do() -> None:
            self._conn.execute(
                "DELETE FROM user_feature_overrides WHERE device_id = ? AND flag_key = ?",
                (device_id, flag_key),
            )

        self._run(_do).result()

    def get_weekly_digest(self, device_id: str) -> dict:
        def _do() -> dict:
            cur = self._conn.cursor()
            now = dt.datetime.now(dt.timezone.utc)
            cutoff      = (now - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
            prev_cutoff = (now - dt.timedelta(days=14)).strftime("%Y-%m-%dT%H:%M:%SZ")

            cur.execute(
                "SELECT COUNT(*) as cnt FROM axis_events WHERE device_id = ? AND ts >= ?",
                (device_id, cutoff),
            )
            total = cur.fetchone()["cnt"]

            cur.execute(
                """SELECT axis, COUNT(*) as cnt
                   FROM axis_events WHERE device_id = ? AND ts >= ?
                   GROUP BY axis ORDER BY cnt DESC""",
                (device_id, cutoff),
            )
            axis_breakdown = {row["axis"]: row["cnt"] for row in cur.fetchall()}

            cur.execute(
                """SELECT axis, COUNT(*) as cnt
                   FROM axis_events WHERE device_id = ? AND ts >= ? AND ts < ?
                   GROUP BY axis ORDER BY cnt DESC""",
                (device_id, prev_cutoff, cutoff),
            )
            prev_axis_breakdown = {row["axis"]: row["cnt"] for row in cur.fetchall()}

            cur.execute(
                """SELECT COUNT(DISTINCT DATE(ts)) as days
                   FROM axis_events WHERE device_id = ? AND ts >= ?""",
                (device_id, cutoff),
            )
            days_active = cur.fetchone()["days"]

            return {
                "period_days": 7,
                "rewrites": total,
                "days_active": days_active,
                "top_axis": next(iter(axis_breakdown), None),
                "axis_breakdown": axis_breakdown,
                "prev_axis_breakdown": prev_axis_breakdown,
            }

        return self._run(_do).result()

    # ---- stripe events ----

    def record_stripe_event(self, event_id: str, type_: str, payload: str) -> str:
        """Insert a new stripe_events row.

        Returns:
          'new'              – never seen; caller must process then call mark_stripe_event_processed.
          'duplicate_ok'     – already successfully processed; safe to ACK 2xx immediately.
          'duplicate_pending' – seen but handler failed last time; caller should retry.
        """
        def _do() -> str:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    "INSERT INTO stripe_events (event_id, received_at, type, payload) VALUES (?, ?, ?, ?)",
                    (event_id, _now_iso(), type_, payload),
                )
                return "new"
            except sqlite3.IntegrityError:
                cur.execute("SELECT processed_at FROM stripe_events WHERE event_id = ?", (event_id,))
                row = cur.fetchone()
                if row and row["processed_at"] is not None:
                    return "duplicate_ok"
                return "duplicate_pending"

        return self._run(_do).result()

    def mark_stripe_event_processed(self, event_id: str) -> None:
        """Stamp a stripe_events row as successfully processed so subsequent
        deliveries of the same event_id are immediately ACK'd 2xx."""
        def _do() -> None:
            self._conn.execute(
                "UPDATE stripe_events SET processed_at = ? WHERE event_id = ?",
                (_now_iso(), event_id),
            )
        self._run(_do).result()

    # ---- Stripe provider projection (provider_purchases + entitlement_grants) ----

    def apply_stripe_subscription_fact(
        self,
        *,
        account_id: Optional[str],
        subscription_id: str,
        stripe_status: str,
        period_end_ms: int,
        product_id: str = "stripe_pro",
        amount_minor: Optional[int] = None,
        currency: Optional[str] = None,
        force: bool = False,
    ) -> str:
        """Project one verified Stripe subscription event into provider_purchases and
        entitlement_grants using the same append-only, version-guarded model as Apple IAP.

        ``amount_minor``/``currency`` carry the plan's authoritative recurring
        price (Stripe ``unit_amount`` + ISO currency); when absent the stored
        value is preserved rather than wiped, so a later event that omits the
        price never blanks a known one.

        period_end_ms (current_period_end × 1000) is the monotonic version oracle:
        older events with a smaller period_end_ms cannot override a newer fact.
        Terminal states (expired/refunded/revoked) cannot be resurrected by active events
        unless force=True (use only for explicit dispute reinstatements).

        Returns the lifecycle_state applied ('active', 'expired', 'stale', …).
        Does NOT touch the mutable accounts.plan columns — callers keep calling
        update_account_subscription for backward compat during the transition.
        """
        lifecycle_state = _STRIPE_STATUS_TO_LIFECYCLE.get(stripe_status, "expired")

        def _do() -> str:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                result = self._apply_stripe_fact_locked(
                    cur, now,
                    account_id=account_id,
                    subscription_id=subscription_id,
                    stripe_status=stripe_status,
                    lifecycle_state=lifecycle_state,
                    period_end_ms=period_end_ms,
                    product_id=product_id,
                    amount_minor=amount_minor,
                    currency=currency,
                    force=force,
                )
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def _apply_stripe_fact_locked(
        self, cur, now, *,
        account_id, subscription_id, stripe_status,
        lifecycle_state, period_end_ms, product_id,
        amount_minor=None, currency=None,
        force=False,
    ) -> str:
        cur.execute(
            "SELECT * FROM provider_purchases WHERE provider = 'stripe' AND original_transaction_id = ?",
            (subscription_id,),
        )
        existing = cur.fetchone()

        if existing is not None:
            stored_ms = existing["latest_signed_ms"] or 0
            stored_state = existing["lifecycle_state"]

            if not force:
                # Terminal states cannot be resurrected by active events
                if stored_state in _TERMINAL_STATES and lifecycle_state == "active":
                    return "stale"
                # Equal-timestamp: terminal beats active
                if period_end_ms == stored_ms and lifecycle_state == "active" and stored_state in _TERMINAL_STATES:
                    return "stale"
                # Genuinely stale active event — newer fact already stored
                if period_end_ms < stored_ms and lifecycle_state == "active":
                    return "stale"

            cur.execute(
                """UPDATE provider_purchases
                      SET lifecycle_state = ?, latest_signed_ms = ?,
                          latest_transaction_id = ?, product_id = ?,
                          app_account_token = COALESCE(?, app_account_token),
                          amount_minor = COALESCE(?, amount_minor),
                          currency = COALESCE(?, currency),
                          expires_ms = ?, updated_at = ?
                    WHERE id = ?""",
                (lifecycle_state, period_end_ms, subscription_id, product_id,
                 account_id, amount_minor, currency, period_end_ms, now, existing["id"]),
            )
            purchase_id = existing["id"]
        else:
            purchase_id = str(uuid.uuid4())
            cur.execute(
                """INSERT INTO provider_purchases
                       (id, provider, original_transaction_id, latest_transaction_id, product_id,
                        environment, ownership_type, app_account_token, lifecycle_state,
                        latest_signed_ms, expires_ms, amount_minor, currency, trial_consumed,
                        created_at, updated_at)
                     VALUES (?, 'stripe', ?, ?, ?, 'production', 'PURCHASED', ?, ?, ?, ?, ?, ?, 0, ?, ?)""",
                (purchase_id, subscription_id, subscription_id, product_id,
                 account_id, lifecycle_state, period_end_ms, period_end_ms,
                 amount_minor, currency, now, now),
            )

        # Grant or revoke entitlement for the account
        if account_id:
            # Guard against orphan grants into non-existent accounts (FK safety)
            cur.execute("SELECT id FROM accounts WHERE id = ?", (account_id,))
            if cur.fetchone() is None:
                import logging as _log
                _log.getLogger(__name__).warning(
                    "apply_stripe_fact: account_id=%s not found; purchase recorded, grant skipped",
                    account_id,
                )
                return lifecycle_state
            if lifecycle_state == "active":
                self._upsert_grant(cur, purchase_id, account_id, "direct", period_end_ms, now)
            else:
                self._revoke_grants_for_purchase(cur, purchase_id, now)

        return lifecycle_state

    def apply_stripe_terminal_fact(
        self,
        *,
        subscription_id: str,
        account_id: Optional[str],
        lifecycle_state: str,
    ) -> str:
        """Apply a terminal fact (refund/dispute reversal) that wins regardless of
        stored version. Uses max(now_ms, stored+1) so no subsequent active event
        can resurrect the terminated purchase.

        Does NOT touch mutable account columns — callers do that separately.
        """
        def _do() -> str:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                cur.execute(
                    "SELECT id, latest_signed_ms FROM provider_purchases "
                    "WHERE provider = 'stripe' AND original_transaction_id = ?",
                    (subscription_id,),
                )
                row = cur.fetchone()
                terminal_ms = _now_ms()

                if row:
                    terminal_ms = max(terminal_ms, (row["latest_signed_ms"] or 0) + 1)
                    cur.execute(
                        """UPDATE provider_purchases
                              SET lifecycle_state = ?, latest_signed_ms = ?,
                                  expires_ms = NULL, updated_at = ?
                            WHERE id = ?""",
                        (lifecycle_state, terminal_ms, now, row["id"]),
                    )
                    self._revoke_grants_for_purchase(cur, row["id"], now)
                else:
                    purchase_id = str(uuid.uuid4())
                    cur.execute(
                        """INSERT INTO provider_purchases
                               (id, provider, original_transaction_id, latest_transaction_id,
                                product_id, environment, ownership_type, app_account_token,
                                lifecycle_state, latest_signed_ms, expires_ms, trial_consumed,
                                created_at, updated_at)
                             VALUES (?, 'stripe', ?, ?, 'stripe_pro', 'production', 'PURCHASED', ?,
                                     ?, ?, NULL, 0, ?, ?)""",
                        (purchase_id, subscription_id, subscription_id, account_id,
                         lifecycle_state, terminal_ms, now, now),
                    )

                cur.execute("COMMIT")
                return lifecycle_state
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def get_account_by_stripe_customer(self, customer_id: str) -> Optional["Account"]:
        """Look up the account that owns a Stripe customer ID."""
        def _do() -> Optional[Account]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT a.* FROM stripe_customer_bindings b
                   JOIN accounts a ON a.id=b.account_id WHERE b.customer_id=?""",
                (customer_id,),
            )
            row = cur.fetchone()
            return _row_to_account(row) if row else None
        return self._run(_do).result()

    def list_accounts_with_stripe_subscriptions(self) -> list:
        """Return accounts that have a stripe_subscription_id — used by reconciliation."""
        def _do() -> list:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT id, stripe_customer_id, stripe_subscription_id, subscription_status "
                "FROM accounts WHERE stripe_subscription_id IS NOT NULL"
            )
            return [dict(r) for r in cur.fetchall()]
        return self._run(_do).result()

    def get_stripe_purchase(self, subscription_id: str) -> Optional[dict]:
        """Return the provider_purchases row for a Stripe subscription, or None."""
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM provider_purchases WHERE provider = 'stripe' AND original_transaction_id = ?",
                (subscription_id,),
            )
            row = cur.fetchone()
            return dict(row) if row else None
        return self._run(_do).result()

    # ---- accounts: provider-identity lookup / in-place upgrade ----

    def get_account_by_provider(self, provider: str, sub: str) -> Optional[Account]:
        assert provider in ("apple", "google", "supabase"), f"unknown provider: {provider}"
        column = f"{provider}_sub"

        def _do() -> Optional[Account]:
            cur = self._conn.cursor()
            cur.execute(f"SELECT * FROM accounts WHERE {column} = ?", (sub,))
            row = cur.fetchone()
            return _row_to_account(row) if row else None

        return self._run(_do).result()

    def backfill_missing_accounts(self) -> dict:
        """One-shot migration: mint exactly one canonical account for every
        device row that still has ``account_id IS NULL`` and link it, copying
        the device's own billing fields so no Pro is lost. Transactional,
        count-checked, and idempotent — a rerun finds nothing null and is a
        no-op; rows that already have an account are never touched (contract
        §1, hostile 3)."""

        def _do() -> dict:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                cur.execute(
                    """SELECT device_id, plan, stripe_customer_id, stripe_subscription_id,
                              subscription_status, subscription_renews_at, coupon_pro_expires_at
                         FROM users WHERE account_id IS NULL"""
                )
                rows = cur.fetchall()
                created = 0
                for r in rows:
                    account_id = str(uuid.uuid4())
                    cur.execute(
                        """INSERT INTO accounts
                               (id, plan, stripe_customer_id, stripe_subscription_id,
                                subscription_status, subscription_renews_at,
                                coupon_pro_expires_at, created_at, updated_at)
                             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                        (
                            account_id, r["plan"] or "free", r["stripe_customer_id"],
                            r["stripe_subscription_id"], r["subscription_status"],
                            r["subscription_renews_at"], r["coupon_pro_expires_at"], now, now,
                        ),
                    )
                    cur.execute(
                        "UPDATE users SET account_id = ?, updated_at = ? "
                        "WHERE device_id = ? AND account_id IS NULL",
                        (account_id, now, r["device_id"]),
                    )
                    if r["coupon_pro_expires_at"] and r["coupon_pro_expires_at"] > now:
                        cur.execute(
                            """INSERT OR IGNORE INTO account_coupon_redemptions
                                   (account_id, code, redeemed_at, expires_at)
                               SELECT ?, code, redeemed_at, ?
                                 FROM coupon_redemptions WHERE device_id = ?""",
                            (account_id, r["coupon_pro_expires_at"], r["device_id"]),
                        )
                    created += 1
                cur.execute("SELECT COUNT(*) AS c FROM users WHERE account_id IS NULL")
                remaining = cur.fetchone()["c"]
                cur.execute("COMMIT")
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise
            return {"backfilled": created, "remaining_null": remaining}

        return self._run(_do).result()

    def backfill_stripe_trial_ledger(self) -> None:
        """Replay the conflict-safe Stripe history backfill after account minting."""
        self._run(self._backfill_stripe_trial_ledger).result()

    # ---- Apple entitlement (build-91) ----

    def apply_apple_transaction(
        self,
        *,
        account_id: str,
        original_transaction_id: str,
        transaction_id: str,
        product_id: str,
        environment: str,
        ownership_type: str,
        app_account_token: Optional[str],
        signed_ms: int,
        expires_ms: Optional[int] = None,
        revocation_ms: Optional[int] = None,
        is_trial: bool = False,
        current_provider_state: Optional[str] = None,
        provider: str = "apple",
    ) -> AppleEntitlementResult:
        """Apply one verified Apple transaction as purchase + grant + claim in a
        single DB transaction (contract §3). Adjudication (direct vs family vs
        tokenless-legacy vs conflict vs stale) is decided against durable state
        so it is idempotent under replay/crash-recovery.

        `current_provider_state` (when supplied by the App Store Server API
        current-provider seam) is authoritative: a terminal live state overrides
        replayed active client proof so a refunded/revoked purchase cannot be
        resurrected (contract §3)."""

        def _do() -> AppleEntitlementResult:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                result = self._apply_apple_tx_locked(
                    cur, now,
                    account_id=account_id,
                    original_transaction_id=original_transaction_id,
                    transaction_id=transaction_id,
                    product_id=product_id,
                    environment=environment,
                    ownership_type=ownership_type,
                    app_account_token=app_account_token,
                    signed_ms=signed_ms,
                    expires_ms=expires_ms,
                    revocation_ms=revocation_ms,
                    is_trial=is_trial,
                    current_provider_state=current_provider_state,
                    provider=provider,
                )
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def _apply_apple_tx_locked(
        self, cur, now, *, account_id, original_transaction_id, transaction_id,
        product_id, environment, ownership_type, app_account_token,
        signed_ms, expires_ms, revocation_ms, is_trial, current_provider_state=None,
        provider="apple",
    ) -> AppleEntitlementResult:
        # Mutation-safety assertions: never grant on unverified identity/ownership.
        assert original_transaction_id and transaction_id, "missing transaction identifiers"
        assert ownership_type in _GRANTABLE_OWNERSHIP, (
            f"refusing to apply transaction with ownership {ownership_type!r}"
        )
        now_ms = _now_ms()
        # Durable inbox record for this transaction id (replay observability).
        with contextlib.suppress(sqlite3.IntegrityError):
            cur.execute(
                "INSERT INTO provider_transactions (provider, event_id, kind, outcome, received_at) "
                "VALUES (?, ?, 'transaction', 'processed', ?)",
                (provider, transaction_id, now),
            )

        cur.execute(
            "SELECT * FROM provider_purchases WHERE provider = ? AND original_transaction_id = ?",
            (provider, original_transaction_id),
        )
        existing = cur.fetchone()

        if revocation_ms is not None:
            incoming_state = "revoked"
        elif expires_ms is not None and expires_ms <= now_ms:
            incoming_state = "expired"
        else:
            incoming_state = "active"

        # Current-provider override (contract §3): when the App Store Server API
        # reports a terminal live state for this lineage, it is authoritative and
        # wins over apparently-active replayed client proof — a refunded/revoked
        # purchase cannot be resurrected even if we never saw the notification.
        if current_provider_state in _TERMINAL_STATES:
            incoming_state = current_provider_state

        # Stale-replay guard: an older signed transaction can never resurrect a
        # terminated purchase (contract §3/§15). Current provider state wins.
        if existing is not None:
            stored_state = existing["lifecycle_state"]
            stored_signed = existing["latest_signed_ms"] or 0
            if (
                stored_state in ("revoked", "refunded", "expired")
                and incoming_state == "active"
                and signed_ms <= stored_signed
            ):
                return AppleEntitlementResult(
                    "revoked", "stale signed transaction cannot resurrect a terminated purchase",
                    purchase_id=existing["id"],
                )

        purchase_id = existing["id"] if existing else str(uuid.uuid4())
        apply_lifecycle = existing is None or signed_ms >= (existing["latest_signed_ms"] or 0)
        trial_flag = 1 if (is_trial or (existing and existing["trial_consumed"])) else 0

        if existing is None:
            cur.execute(
                """INSERT INTO provider_purchases
                       (id, provider, original_transaction_id, latest_transaction_id, product_id,
                        environment, ownership_type, app_account_token, lifecycle_state,
                        latest_signed_ms, expires_ms, trial_consumed, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (purchase_id, provider, original_transaction_id, transaction_id, product_id,
                 environment, ownership_type, app_account_token, incoming_state,
                 signed_ms, expires_ms, trial_flag, now, now),
            )
            effective_state = incoming_state
        elif apply_lifecycle:
            cur.execute(
                """UPDATE provider_purchases
                      SET latest_transaction_id = ?, product_id = ?, environment = ?,
                          ownership_type = ?,
                          app_account_token = COALESCE(?, app_account_token),
                          lifecycle_state = ?, latest_signed_ms = ?, expires_ms = ?,
                          trial_consumed = ?, updated_at = ?
                    WHERE id = ?""",
                (transaction_id, product_id, environment, ownership_type, app_account_token,
                 incoming_state, signed_ms, expires_ms, trial_flag, now, purchase_id),
            )
            effective_state = incoming_state
        else:
            # Older-but-not-a-resurrection: keep trial_consumed sticky, but the
            # authoritative lifecycle stays whatever the newest evidence set.
            if trial_flag and not existing["trial_consumed"]:
                cur.execute(
                    "UPDATE provider_purchases SET trial_consumed = 1, updated_at = ? WHERE id = ?",
                    (now, purchase_id),
                )
            effective_state = existing["lifecycle_state"]

        if effective_state != "active":
            self._revoke_grants_for_purchase(cur, purchase_id, now)
            return AppleEntitlementResult("not_active", f"purchase is {effective_state}", purchase_id=purchase_id)

        # FAMILY_SHARED — revocable beneficiary grant only; no token, no
        # ownership, no account recovery authority (contract §6).
        if ownership_type == "FAMILY_SHARED":
            self._upsert_grant(cur, purchase_id, account_id, "family", expires_ms, now)
            return AppleEntitlementResult("family_granted", purchase_id=purchase_id)

        # PURCHASED with a bound appAccountToken.
        if app_account_token:
            if app_account_token == account_id:
                self._upsert_grant(cur, purchase_id, account_id, "direct", expires_ms, now)
                return AppleEntitlementResult("direct_granted", purchase_id=purchase_id)
            # Non-null token belonging to another account -> deterministic
            # conflict. Never fall through to the tokenless legacy path
            # (contract §4, hostile 9).
            return AppleEntitlementResult(
                "conflict", "purchase is bound to a different account", purchase_id=purchase_id
            )

        # PURCHASED tokenless -> permanent legacy claim. The UNIQUE lineage
        # constraint selects the single first claimant (contract §5).
        cur.execute(
            "SELECT * FROM legacy_claims WHERE provider = ? AND original_transaction_id = ?",
            (provider, original_transaction_id),
        )
        claim = cur.fetchone()
        if claim is None:
            try:
                cur.execute(
                    """INSERT INTO legacy_claims
                           (id, provider, original_transaction_id, claimant_account_id,
                            evidence_key, result, claimed_at)
                         VALUES (?, ?, ?, ?, ?, 'granted', ?)""",
                    (str(uuid.uuid4()), provider, original_transaction_id, account_id, transaction_id, now),
                )
            except sqlite3.IntegrityError:
                cur.execute(
                    "SELECT * FROM legacy_claims WHERE provider = ? AND original_transaction_id = ?",
                    (provider, original_transaction_id),
                )
                claim = cur.fetchone()
        if claim is not None and claim["claimant_account_id"] != account_id:
            return AppleEntitlementResult(
                "conflict", "purchase already claimed by another account", purchase_id=purchase_id
            )
        # Winner: fresh claim, or idempotent retry by the same account.
        self._upsert_grant(cur, purchase_id, account_id, "direct", expires_ms, now)
        self._record_set_token_op(cur, provider, original_transaction_id, account_id, now)
        return AppleEntitlementResult("legacy_granted", purchase_id=purchase_id)

    def _upsert_grant(self, cur, purchase_id, account_id, grant_kind, expires_ms, now) -> None:
        expires_at = _ms_to_iso(expires_ms)
        cur.execute(
            "SELECT id FROM entitlement_grants WHERE purchase_id = ? AND account_id = ?",
            (purchase_id, account_id),
        )
        g = cur.fetchone()
        if g:
            cur.execute(
                """UPDATE entitlement_grants
                      SET grant_kind = ?, state = 'active',
                          effective_at = COALESCE(effective_at, ?),
                          expires_at = ?, revoked_at = NULL, updated_at = ?
                    WHERE id = ?""",
                (grant_kind, now, expires_at, now, g["id"]),
            )
        else:
            cur.execute(
                """INSERT INTO entitlement_grants
                       (id, purchase_id, account_id, grant_kind, state, effective_at,
                        expires_at, revoked_at, created_at, updated_at)
                     VALUES (?, ?, ?, ?, 'active', ?, ?, NULL, ?, ?)""",
                (str(uuid.uuid4()), purchase_id, account_id, grant_kind, now, expires_at, now, now),
            )

    def _revoke_grants_for_purchase(self, cur, purchase_id, now, only_account: Optional[str] = None) -> None:
        if only_account is not None:
            cur.execute(
                "UPDATE entitlement_grants SET state = 'revoked', revoked_at = ?, updated_at = ? "
                "WHERE purchase_id = ? AND account_id = ? AND state = 'active'",
                (now, now, purchase_id, only_account),
            )
        else:
            cur.execute(
                "UPDATE entitlement_grants SET state = 'revoked', revoked_at = ?, updated_at = ? "
                "WHERE purchase_id = ? AND state = 'active'",
                (now, now, purchase_id),
            )

    def _record_set_token_op(self, cur, provider, original_transaction_id, account_id, now) -> None:
        with contextlib.suppress(sqlite3.IntegrityError):
            cur.execute(
                """INSERT INTO provider_operations
                       (id, provider, op_kind, original_transaction_id, account_id,
                        state, attempts, created_at, updated_at)
                     VALUES (?, ?, 'set_app_account_token', ?, ?, 'pending', 0, ?, ?)""",
                (str(uuid.uuid4()), provider, original_transaction_id, account_id, now, now),
            )

    # ---- RevenueCat canary: durable inbox + provider projection ----

    def record_revenuecat_event(
        self,
        *,
        event_id: str,
        event_type: str,
        payload: str,
        app_user_id: Optional[str],
        store_source: Optional[str],
        environment: Optional[str],
        event_ms: int,
    ) -> str:
        """Insert a new revenuecat_events inbox row keyed by the RevenueCat event
        id (the provider's own idempotency key). Returns:
          'new'               – never seen; caller must process then mark_* it.
          'duplicate_ok'      – already terminal (processed/dead_letter); ACK 2xx now.
          'duplicate_pending' – seen but not terminal; re-process idempotently.
        A genuine (non-duplicate) INSERT failure propagates so the caller returns a
        retryable 5xx — the durable-inbox-failure contract (§5)."""
        def _do() -> str:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    "INSERT INTO revenuecat_events (event_id, event_type, app_user_id, "
                    "store_source, environment, event_ms, payload, state, attempts, received_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, 'received', 0, ?)",
                    (event_id, event_type, app_user_id, store_source, environment,
                     int(event_ms or 0), payload, _now_iso()),
                )
                return "new"
            except sqlite3.IntegrityError:
                cur.execute("SELECT state FROM revenuecat_events WHERE event_id = ?", (event_id,))
                row = cur.fetchone()
                if row and row["state"] in ("processed", "dead_letter"):
                    return "duplicate_ok"
                return "duplicate_pending"

        return self._run(_do).result()

    def mark_revenuecat_event_processed(self, event_id: str, outcome: str) -> None:
        """Stamp an inbox row terminally processed so replays ACK 2xx immediately."""
        def _do() -> None:
            self._conn.execute(
                "UPDATE revenuecat_events SET state='processed', outcome=?, "
                "processed_at=?, last_error=NULL WHERE event_id=?",
                (outcome[:200], _now_iso(), event_id),
            )
        self._run(_do).result()

    def mark_revenuecat_event_failed(self, event_id: str, error: str) -> int:
        """Mark an event failed (retryable) and bump attempts. Returns the new
        attempt count so the caller can escalate to dead-letter past a ceiling."""
        def _do() -> int:
            cur = self._conn.cursor()
            cur.execute(
                "UPDATE revenuecat_events SET state='failed', attempts=attempts+1, "
                "last_error=? WHERE event_id=?",
                ((error or "")[:2000], event_id),
            )
            cur.execute("SELECT attempts FROM revenuecat_events WHERE event_id=?", (event_id,))
            row = cur.fetchone()
            return int(row["attempts"]) if row else 0
        return self._run(_do).result()

    def mark_revenuecat_event_dead_letter(self, event_id: str, reason: str) -> None:
        """Move an event to the terminal dead-letter state (deterministic failure
        or retry ceiling reached). Replays then ACK 2xx and the reconciler skips it."""
        def _do() -> None:
            self._conn.execute(
                "UPDATE revenuecat_events SET state='dead_letter', outcome=?, "
                "last_error=? WHERE event_id=?",
                (f"dead_letter:{reason}"[:200], (reason or "")[:2000], event_id),
            )
        self._run(_do).result()

    def get_revenuecat_event(self, event_id: str) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM revenuecat_events WHERE event_id=?", (event_id,))
            row = cur.fetchone()
            return dict(row) if row else None
        return self._run(_do).result()

    def list_revenuecat_events_for_retry(
        self, *, limit: int = 100, max_attempts: int = 8
    ) -> list[dict]:
        """Non-terminal events (received/failed) under the retry ceiling, oldest
        first — the reconciler drains these. Events at/over max_attempts are left
        for the caller to dead-letter."""
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM revenuecat_events WHERE state IN ('received','failed') "
                "AND attempts < ? ORDER BY id ASC LIMIT ?",
                (int(max_attempts), int(limit)),
            )
            return [dict(r) for r in cur.fetchall()]
        return self._run(_do).result()

    def apply_revenuecat_fact(
        self,
        *,
        account_id: Optional[str],
        original_transaction_id: str,
        product_id: str,
        lifecycle_state: str,
        entitled: bool,
        signed_ms: int,
        expires_ms: Optional[int],
        environment: str = "production",
        hard_terminal: bool = False,
        write_grant: bool = True,
        force: bool = False,
    ) -> str:
        """Project one AUTHENTICATED RevenueCat event into provider_purchases
        (provider='revenuecat') and — only when ``write_grant`` (authoritative
        mode) — into entitlement_grants, using the same append-only, version-
        guarded model as the Apple/Stripe/Google writers.

        ``signed_ms`` (the RevenueCat event timestamp) is the monotonic version
        oracle: an older non-terminal event can never override a newer stored fact,
        and a terminal state can never be resurrected by an active event (unless
        ``force``). ``hard_terminal`` (refund / chargeback / revoke) always wins and
        bumps the version so no later-arriving active/older event can undo it.

        In shadow mode (``write_grant=False``) the append-only provider fact is
        still recorded for reconciliation, but NO grant is written/revoked, so the
        legacy projection stays the sole entitlement writer (canary boundary, §6).
        Returns the applied lifecycle_state, or 'stale' when a newer fact wins.
        Never touches the mutable accounts.plan columns."""
        def _do() -> str:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                result = self._apply_revenuecat_fact_locked(
                    cur, now,
                    account_id=account_id,
                    original_transaction_id=original_transaction_id,
                    product_id=product_id,
                    lifecycle_state=lifecycle_state,
                    entitled=entitled,
                    signed_ms=signed_ms,
                    expires_ms=expires_ms,
                    environment=environment,
                    hard_terminal=hard_terminal,
                    write_grant=write_grant,
                    force=force,
                )
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def _apply_revenuecat_fact_locked(
        self, cur, now, *,
        account_id, original_transaction_id, product_id, lifecycle_state,
        entitled, signed_ms, expires_ms, environment,
        hard_terminal=False, write_grant=True, force=False,
    ) -> str:
        cur.execute(
            "SELECT * FROM provider_purchases WHERE provider='revenuecat' "
            "AND original_transaction_id = ?",
            (original_transaction_id,),
        )
        existing = cur.fetchone()

        if existing is not None:
            stored_ms = existing["latest_signed_ms"] or 0
            stored_state = existing["lifecycle_state"]
            if hard_terminal and not force:
                # Refund/chargeback/revoke always wins; bump past the stored version.
                signed_ms = max(signed_ms, stored_ms + 1)
            elif not force:
                # Out-of-order safety (contract §9): a terminal lineage is never
                # resurrected by a non-hard event, and an older soft event (active
                # OR expired) never overrides a newer stored fact. Only a genuine
                # hard-terminal (above) or an explicit force reinstatement bypasses
                # this. An equal-timestamp replay falls through as an idempotent
                # no-op update.
                if stored_state in _TERMINAL_STATES:
                    return "stale"
                if signed_ms < stored_ms:
                    return "stale"

            cur.execute(
                """UPDATE provider_purchases
                      SET lifecycle_state = ?, latest_signed_ms = ?,
                          latest_transaction_id = ?, product_id = ?,
                          app_account_token = COALESCE(?, app_account_token),
                          expires_ms = ?, environment = ?, updated_at = ?
                    WHERE id = ?""",
                (lifecycle_state, signed_ms, original_transaction_id, product_id,
                 account_id, expires_ms, environment, now, existing["id"]),
            )
            purchase_id = existing["id"]
        else:
            purchase_id = str(uuid.uuid4())
            cur.execute(
                """INSERT INTO provider_purchases
                       (id, provider, original_transaction_id, latest_transaction_id, product_id,
                        environment, ownership_type, app_account_token, lifecycle_state,
                        latest_signed_ms, expires_ms, trial_consumed, created_at, updated_at)
                     VALUES (?, 'revenuecat', ?, ?, ?, ?, 'PURCHASED', ?, ?, ?, ?, 0, ?, ?)""",
                (purchase_id, original_transaction_id, original_transaction_id, product_id,
                 environment, account_id, lifecycle_state, signed_ms, expires_ms, now, now),
            )

        # Grant/revoke ONLY in authoritative mode (shadow records the fact but
        # never mutates entitlement — the legacy path stays the sole writer).
        if write_grant:
            if entitled and lifecycle_state not in _TERMINAL_STATES:
                # Granting requires a REAL account (fail closed on a missing or
                # unknown/attacker-supplied app_user_id — the fact is still
                # recorded above with the claimed binding, but no grant is made).
                if account_id and _account_exists(cur, account_id):
                    self._upsert_grant(cur, purchase_id, account_id, "direct", expires_ms, now)
                elif account_id:
                    import logging as _log
                    _log.getLogger(__name__).warning(
                        "apply_revenuecat_fact: account_id=%s not found; fact recorded, grant skipped",
                        account_id,
                    )
            else:
                # Revoking a lineage (refund / revoke / expiry / transfer-away)
                # never needs a beneficiary — revoke every active grant on it,
                # even when the event carries no account_id.
                self._revoke_grants_for_purchase(cur, purchase_id, now)

        return lifecycle_state

    def record_revenuecat_shadow_observation(
        self,
        *,
        event_id: str,
        account_id: Optional[str],
        revenuecat_active: bool,
        legacy_active: bool,
        mode: str,
        store_source: Optional[str] = None,
        detail: Optional[str] = None,
    ) -> bool:
        """Append a canary comparison of the RevenueCat-derived entitlement against
        the legacy projection. Idempotent by event_id (a duplicate delivery updates
        the one row in place, never adds a second observation). `store_source` is
        the RevenueCat `store` this observation came from; it is the flip-eligibility
        class key (a PROMOTIONAL admin grant is excluded from the flip decision).
        Returns True when the two agree (both entitled or both not)."""
        agree = bool(revenuecat_active) == bool(legacy_active)
        def _do() -> None:
            self._conn.execute(
                "INSERT INTO revenuecat_shadow_observations "
                "(event_id, account_id, store_source, revenuecat_active, legacy_active, agree, mode, detail, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(event_id) DO UPDATE SET account_id=excluded.account_id, "
                "store_source=excluded.store_source, "
                "revenuecat_active=excluded.revenuecat_active, legacy_active=excluded.legacy_active, "
                "agree=excluded.agree, mode=excluded.mode, detail=excluded.detail",
                (event_id, account_id, (store_source or None), 1 if revenuecat_active else 0,
                 1 if legacy_active else 0, 1 if agree else 0, mode,
                 (detail or None), _now_iso()),
            )
        self._run(_do).result()
        return agree

    def revenuecat_shadow_disagreements(self, *, limit: int = 100) -> list[dict]:
        """Canary reconciliation hook: RevenueCat-vs-legacy disagreements, newest
        first. In a healthy shadow this is empty."""
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM revenuecat_shadow_observations WHERE agree=0 "
                "ORDER BY id DESC LIMIT ?",
                (int(limit),),
            )
            return [dict(r) for r in cur.fetchall()]
        return self._run(_do).result()

    def revenuecat_shadow_summary(self) -> dict:
        """Non-secret aggregate of the shadow canary ledger for operator readiness:
        total observations, agreements, disagreements, and the newest observation
        timestamp. COUNTS ONLY — no account/user identifiers — so it is safe to
        surface on the unauthenticated readiness probe. In a healthy shadow window
        `disagreements` is 0, which is the gate for flipping shadow -> authoritative
        (contract §9)."""
        def _do() -> dict:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT COUNT(*) AS total, "
                "COALESCE(SUM(agree), 0) AS agreements, "
                "COALESCE(SUM(1 - agree), 0) AS disagreements, "
                "MAX(created_at) AS last_observed_at "
                "FROM revenuecat_shadow_observations"
            )
            row = cur.fetchone()
            return {
                "total": int(row["total"] or 0),
                "agreements": int(row["agreements"] or 0),
                "disagreements": int(row["disagreements"] or 0),
                "last_observed_at": row["last_observed_at"],
            }
        return self._run(_do).result()

    def revenuecat_shadow_flip_summary(self) -> dict:
        """Flip-eligibility breakdown of the shadow ledger — the population the
        shadow->authoritative cutover decision is ACTUALLY allowed to be computed
        from. It separates real store-parity canaries (App Store/Play/Stripe/RC
        Billing/... — 'eligible') from two kinds of non-store observation that are
        retained in lifetime diagnostics but are NEVER a flip signal:
        RevenueCat PROMOTIONAL admin grants ('excluded_promotional') and
        self-issued/TEST_STORE integration canaries ('excluded_synthetic'). Both
        make RevenueCat active with no store purchase and thus legitimately
        disagree with the free legacy projection in shadow mode; a synthetic
        canary is kept in its own bucket so a signed transport probe stays durably
        auditable without ever qualifying as real store evidence.

        The store class is derived per observation from its own `store_source`,
        falling back to the durable revenuecat_events row for pre-migration rows
        (LEFT JOIN on event_id + COALESCE) so existing deployed promotional rows
        are classified correctly after upgrade, not just new inserts. An
        observation whose store cannot be classified is counted as
        `unclassified` and FAILS CLOSED — it is never silently folded into either
        the eligible-clean or the excluded-promotional bucket (contract §6
        corrective). COUNTS ONLY — no identifiers — safe for the readiness probe.
        """
        def _do() -> dict:
            cur = self._conn.cursor()
            # A row counts as an AGREEMENT when it originally agreed OR when a
            # later re-query of RevenueCat's current truth reconciled it (the
            # historical disagreement is stale — RC no longer supports it). A real
            # standing disagreement is never reconciled, so it stays counted here.
            cur.execute(
                "SELECT COALESCE(o.store_source, e.store_source) AS eff_store, "
                "       CASE WHEN o.agree = 1 OR o.reconciled_at IS NOT NULL "
                "            THEN 1 ELSE 0 END AS eff_agree, COUNT(*) AS n "
                "  FROM revenuecat_shadow_observations o "
                "  LEFT JOIN revenuecat_events e ON e.event_id = o.event_id "
                " GROUP BY eff_store, eff_agree"
            )
            eligible_total = eligible_agree = eligible_disagree = 0
            excluded_promotional = 0
            excluded_synthetic = 0
            unclassified = 0
            for row in cur.fetchall():
                klass = _classify_rc_store(row["eff_store"])
                n = int(row["n"] or 0)
                if klass == "promotional":
                    excluded_promotional += n
                elif klass == "synthetic":
                    excluded_synthetic += n
                elif klass == "eligible":
                    eligible_total += n
                    if int(row["eff_agree"] or 0) == 1:
                        eligible_agree += n
                    else:
                        eligible_disagree += n
                else:  # 'unknown' -> fail closed; never promotional, never clean
                    unclassified += n
            return {
                "eligible": {
                    "total": eligible_total,
                    "agreements": eligible_agree,
                    "disagreements": eligible_disagree,
                },
                "excluded_promotional": excluded_promotional,
                "excluded_synthetic": excluded_synthetic,
                "unclassified": unclassified,
            }
        return self._run(_do).result()

    def revenuecat_shadow_flip_disagreements(self, limit: int = 50) -> list[dict]:
        """Per-observation detail for the flip-eligible (real store-parity)
        DISAGREEMENTS only — the exact rows that hold `shadow_clean` false and
        block the shadow->authoritative cutover. Returned to an AUTHENTICATED
        operator (the endpoint gates on the webhook Authorization secret) so the
        cause of a stuck flip can be diagnosed without prod DB access.

        Fields are diagnostic, not a data export: the RevenueCat/account
        identifiers here are the SAME ones the operator already administers in the
        RevenueCat dashboard. No password, token, email, or raw payload is
        included. Only rows whose effective store classifies as 'eligible' (a real
        store) and whose `agree` is 0 are returned; promotional/synthetic/unknown
        are excluded exactly as they are from the flip decision."""
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT o.event_id AS event_id, o.account_id AS account_id, "
                "       COALESCE(o.store_source, e.store_source) AS eff_store, "
                "       e.event_type AS event_type, "
                "       o.revenuecat_active AS rc_active, o.legacy_active AS legacy_active, "
                "       o.detail AS detail, o.created_at AS created_at "
                "  FROM revenuecat_shadow_observations o "
                "  LEFT JOIN revenuecat_events e ON e.event_id = o.event_id "
                " WHERE o.agree = 0 AND o.reconciled_at IS NULL "
                " ORDER BY o.id DESC"
            )
            out: list[dict] = []
            for row in cur.fetchall():
                if _classify_rc_store(row["eff_store"]) != "eligible":
                    continue  # only real store-parity disagreements block the flip
                out.append({
                    "event_id": row["event_id"],
                    "account_id": row["account_id"],
                    "store_source": row["eff_store"],
                    "event_type": row["event_type"],
                    "revenuecat_active": bool(row["rc_active"]),
                    "legacy_active": bool(row["legacy_active"]),
                    "detail": row["detail"],
                    "created_at": row["created_at"],
                })
                if len(out) >= max(1, min(int(limit), 500)):
                    break
            return out
        return self._run(_do).result()

    def list_flip_eligible_disagreements_for_reconcile(self) -> list[dict]:
        """The UNRECONCILED flip-eligible disagreements the re-query reconciler
        must check against RevenueCat's current truth. Returns (event_id,
        account_id, legacy_active) for each — the reconciler asks RevenueCat
        whether the account currently has access and, only if RC now AGREES with
        the recorded legacy state, marks the row reconciled. Real standing
        disagreements (RC still active) are returned here but never reconciled."""
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT o.event_id AS event_id, o.account_id AS account_id, "
                "       o.legacy_active AS legacy_active, "
                "       COALESCE(o.store_source, e.store_source) AS eff_store "
                "  FROM revenuecat_shadow_observations o "
                "  LEFT JOIN revenuecat_events e ON e.event_id = o.event_id "
                " WHERE o.agree = 0 AND o.reconciled_at IS NULL"
            )
            out = []
            for row in cur.fetchall():
                if _classify_rc_store(row["eff_store"]) != "eligible":
                    continue
                if not row["account_id"]:
                    continue  # no account to re-query -> leave it blocking (fail closed)
                out.append({
                    "event_id": row["event_id"],
                    "account_id": row["account_id"],
                    "legacy_active": bool(row["legacy_active"]),
                })
            return out
        return self._run(_do).result()

    def mark_shadow_observation_reconciled(self, event_id: str, when_iso: str) -> None:
        """Record that RevenueCat's current truth confirmed this historical
        disagreement is stale. Additive annotation only — the observation's
        original facts are left intact; only the previously-NULL reconciled_at is
        set, and only when still NULL (idempotent)."""
        def _do() -> None:
            self._conn.execute(
                "UPDATE revenuecat_shadow_observations SET reconciled_at = ? "
                " WHERE event_id = ? AND reconciled_at IS NULL",
                (when_iso, event_id),
            )
            self._conn.commit()
        self._run(_do).result()

    def apply_apple_notification(
        self,
        *,
        notification_uuid: str,
        notification_type: str,
        original_transaction_id: str,
        signed_ms: int,
        subtype: Optional[str] = None,
        ownership_type: Optional[str] = None,
        beneficiary_account_id: Optional[str] = None,
        expires_ms: Optional[int] = None,
        provider: str = "apple",
    ) -> str:
        """Apply one verified App Store Server Notification V2. Deduped by
        notificationUUID; older-than-current events are ignored, and on an EQUAL
        provider timestamp a terminal state deterministically beats an active
        event so a refund/revoke/expire can never be resurrected (contract §3,
        hostile 15/16; P0 equal-timestamp resurrection).

        `ownership_type` is the verified nested-transaction ownership. A
        FAMILY_SHARED-scoped terminal event revokes ONLY a proven beneficiary
        grant; if no beneficiary can be proven it is parked as a non-destructive
        unresolved event rather than mass-revoking every beneficiary (contract
        §6; P0 tokenless family revoke)."""

        terminal = {
            "REFUND": "refunded",
            "REVOKE": "revoked",
            "EXPIRED": "expired",
            "GRACE_PERIOD_EXPIRED": "expired",
        }
        active = {"SUBSCRIBED", "DID_RENEW", "OFFER_REDEEMED", "RESUBSCRIBE"}

        def _do() -> str:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                try:
                    cur.execute(
                        "INSERT INTO provider_transactions (provider, event_id, kind, outcome, received_at) "
                        "VALUES (?, ?, 'notification', ?, ?)",
                        (provider, notification_uuid, notification_type, now),
                    )
                except sqlite3.IntegrityError:
                    cur.execute("COMMIT")
                    return "duplicate"

                cur.execute(
                    "SELECT * FROM provider_purchases WHERE provider = ? AND original_transaction_id = ?",
                    (provider, original_transaction_id),
                )
                purchase = cur.fetchone()
                if purchase is None:
                    cur.execute("COMMIT")
                    return "unknown_purchase"

                stored_signed = purchase["latest_signed_ms"] or 0
                stored_state = purchase["lifecycle_state"]
                is_terminal_event = notification_type in terminal
                is_active_event = notification_type in active
                # Out-of-order guard: ignore an event strictly older than the
                # newest we've already applied. Current provider state wins.
                if signed_ms < stored_signed:
                    cur.execute("COMMIT")
                    return "stale"
                # Equal-timestamp precedence (P0): a terminal state beats an
                # active event on a tie, so an equal-or-older active event can
                # never resurrect a refunded/revoked/expired purchase. Terminal
                # events still apply on a tie (terminal-over-active), preserving
                # idempotence for a re-delivered terminal notification.
                if (
                    signed_ms == stored_signed
                    and is_active_event
                    and stored_state in _TERMINAL_STATES
                ):
                    cur.execute("COMMIT")
                    return "stale"

                if is_terminal_event:
                    new_state = terminal[notification_type]
                    if ownership_type == "FAMILY_SHARED":
                        # Family-scoped revoke: only a cryptographically present,
                        # valid beneficiary token that maps to an EXISTING family
                        # grant proves whom to revoke. Never touch the purchase
                        # lifecycle or any other beneficiary/purchaser grant.
                        if beneficiary_account_id is not None and _purchase_has_active_grant(
                            cur, purchase["id"], beneficiary_account_id
                        ):
                            self._revoke_grants_for_purchase(
                                cur, purchase["id"], now, only_account=beneficiary_account_id
                            )
                            outcome = "beneficiary_revoked"
                        else:
                            # No provable beneficiary -> fail closed: park the
                            # event for provider reconciliation, mutate nothing.
                            self._record_unresolved_event(
                                cur, provider, notification_uuid, notification_type,
                                original_transaction_id, "family_revoke_no_provable_beneficiary", now,
                            )
                            outcome = "unresolved_beneficiary"
                    else:
                        # Purchaser/direct-scoped terminal: the whole lineage ends.
                        cur.execute(
                            "UPDATE provider_purchases SET lifecycle_state = ?, latest_signed_ms = ?, updated_at = ? WHERE id = ?",
                            (new_state, signed_ms, now, purchase["id"]),
                        )
                        self._revoke_grants_for_purchase(cur, purchase["id"], now)
                        outcome = new_state
                elif is_active_event:
                    cur.execute(
                        "UPDATE provider_purchases SET lifecycle_state = 'active', latest_signed_ms = ?, "
                        "expires_ms = COALESCE(?, expires_ms), updated_at = ? WHERE id = ?",
                        (signed_ms, expires_ms, now, purchase["id"]),
                    )
                    # Re-activate this purchase's grants and refresh expiry.
                    cur.execute(
                        "UPDATE entitlement_grants SET state = 'active', revoked_at = NULL, "
                        "expires_at = COALESCE(?, expires_at), updated_at = ? WHERE purchase_id = ?",
                        (_ms_to_iso(expires_ms), now, purchase["id"]),
                    )
                    outcome = "active"
                else:
                    outcome = "ignored"

                cur.execute("COMMIT")
                return outcome
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def _record_unresolved_event(
        self, cur, provider, notification_uuid, notification_type,
        original_transaction_id, reason, now,
    ) -> None:
        with contextlib.suppress(sqlite3.IntegrityError):
            cur.execute(
                """INSERT INTO provider_unresolved_events
                       (id, provider, notification_uuid, notification_type,
                        original_transaction_id, reason, created_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (str(uuid.uuid4()), provider, notification_uuid, notification_type,
                 original_transaction_id, reason, now),
            )

    # ---- Google Play provider projection (provider_purchases + entitlement_grants) ----

    def record_provider_notification(
        self, provider: str, event_id: str, notification_type: str
    ) -> bool:
        """Reserve a durable notification for processing.

        Completed messages are duplicates. A pending message is deliberately
        retryable after a transient failure or process crash.
        """

        def _do() -> bool:
            cur = self._conn.cursor()
            try:
                cur.execute(
                    "INSERT INTO provider_transactions (provider, event_id, kind, outcome, received_at) "
                    "VALUES (?, ?, 'notification', ?, ?)",
                    (provider, event_id, f"pending:{notification_type}", _now_iso()),
                )
                return True
            except sqlite3.IntegrityError:
                row = cur.execute(
                    "SELECT outcome FROM provider_transactions WHERE provider = ? AND event_id = ?",
                    (provider, event_id),
                ).fetchone()
                return bool(row and row["outcome"].startswith("pending:"))

        return self._run(_do).result()

    def complete_provider_notification(
        self, provider: str, event_id: str, outcome: str
    ) -> None:
        """Mark a reserved inbox message completed only after projection."""

        def _do() -> None:
            self._conn.execute(
                "UPDATE provider_transactions SET outcome = ? "
                "WHERE provider = ? AND event_id = ? AND outcome LIKE 'pending:%'",
                (f"completed:{outcome}", provider, event_id),
            )

        self._run(_do).result()

    def apply_google_purchase(
        self,
        *,
        account_id: Optional[str],
        purchase_token: str,
        subscription_id: str,
        obfuscated_account_id: Optional[str],
        lifecycle_state: str,
        entitled: bool,
        hard_terminal: bool,
        signed_ms: int,
        expires_ms: Optional[int] = None,
        environment: str = "production",
        linked_purchase_token: Optional[str] = None,
        acknowledged: bool = False,
        provider: str = "google",
    ) -> GoogleEntitlementResult:
        """Project ONE server-verified Google Play subscription snapshot into the
        same append-only provider_purchases -> entitlement_grants model Apple and
        Stripe use, keyed by the purchase token as the lineage id (contract §3).

        The snapshot MUST come from a server-side Developer API re-query — never
        from a client or an RTDN payload. `entitled`/`hard_terminal`/
        `lifecycle_state` are the normalized decision the verified provider state
        yields; this method only persists it deterministically and idempotently.

        Beneficiary binding (contract §1/§4):
          * `obfuscated_account_id` (obfuscatedExternalAccountId, set by the
            client at purchase) is the authoritative person binding when present.
            On the authenticated direct-sync path a value that disagrees with the
            caller's `account_id` is a hard conflict — a token cannot be claimed
            across accounts.
          * absent it, the first authenticated account to register the token wins
            via the shared legacy_claims lineage lock; a later different account
            conflicts.
          * `account_id` is None on the unauthenticated RTDN path: an existing
            lineage's grants are reconciled in place, and a brand-new purchase
            with a provable obfuscated beneficiary is bound, but a beneficiary we
            cannot prove is recorded 'unbound' rather than guessed.

        Terminal precedence: a hard-terminal state (refunded/revoked/replaced)
        can never be resurrected, and an equal-or-older active re-query can never
        revive an expired lineage (deterministic, replay-safe)."""

        def _do() -> GoogleEntitlementResult:
            cur = self._conn.cursor()
            now = _now_iso()
            cur.execute("BEGIN IMMEDIATE")
            try:
                result = self._apply_google_purchase_locked(
                    cur, now,
                    account_id=account_id,
                    purchase_token=purchase_token,
                    subscription_id=subscription_id,
                    obfuscated_account_id=obfuscated_account_id,
                    lifecycle_state=lifecycle_state,
                    entitled=entitled,
                    hard_terminal=hard_terminal,
                    signed_ms=signed_ms,
                    expires_ms=expires_ms,
                    environment=environment,
                    linked_purchase_token=linked_purchase_token,
                    acknowledged=acknowledged,
                    provider=provider,
                )
                cur.execute("COMMIT")
                return result
            except Exception:
                with contextlib.suppress(sqlite3.Error):
                    cur.execute("ROLLBACK")
                raise

        return self._run(_do).result()

    def _apply_google_purchase_locked(
        self, cur, now, *, account_id, purchase_token, subscription_id,
        obfuscated_account_id, lifecycle_state, entitled, hard_terminal,
        signed_ms, expires_ms, environment, linked_purchase_token,
        acknowledged, provider,
    ) -> GoogleEntitlementResult:
        assert purchase_token and subscription_id, "missing google purchase identifiers"

        # Resolve both sides of a replacement before touching either lineage.
        # A linked token is continuity evidence, never authority to transfer a
        # subscription between canonical accounts.
        new_beneficiary = obfuscated_account_id or account_id
        if new_beneficiary is None:
            cur.execute(
                """SELECT eg.account_id
                     FROM provider_purchases pp
                     JOIN entitlement_grants eg ON eg.purchase_id = pp.id
                    WHERE pp.provider = ? AND pp.original_transaction_id = ?
                    ORDER BY CASE eg.state WHEN 'active' THEN 0 ELSE 1 END
                    LIMIT 1""",
                (provider, purchase_token),
            )
            new_row = cur.fetchone()
            new_beneficiary = new_row["account_id"] if new_row else None

        old = None
        old_beneficiary = None
        if linked_purchase_token and linked_purchase_token != purchase_token:
            cur.execute(
                "SELECT * FROM provider_purchases WHERE provider = ? AND original_transaction_id = ?",
                (provider, linked_purchase_token),
            )
            old = cur.fetchone()
            if old is not None:
                cur.execute(
                    """SELECT account_id FROM entitlement_grants
                        WHERE purchase_id = ?
                        ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END
                        LIMIT 1""",
                    (old["id"],),
                )
                old_grant = cur.fetchone()
                old_beneficiary = old_grant["account_id"] if old_grant else None
                if (
                    old_beneficiary is not None
                    and new_beneficiary is not None
                    and old_beneficiary != new_beneficiary
                ):
                    return GoogleEntitlementResult(
                        "conflict",
                        "linked purchase belongs to a different account",
                        lifecycle_state=lifecycle_state,
                    )

        cur.execute(
            "SELECT * FROM provider_purchases WHERE provider = ? AND original_transaction_id = ?",
            (provider, purchase_token),
        )
        existing = cur.fetchone()

        if existing is not None:
            stored_state = existing["lifecycle_state"]
            stored_signed = existing["latest_signed_ms"] or 0
            # Hard-terminal is permanent. A still-active re-query (a stale client
            # replay, or a provider lag) must not resurrect it.
            if stored_state in _GOOGLE_HARD_TERMINAL and not hard_terminal:
                if entitled:
                    return GoogleEntitlementResult(
                        "stale", f"{stored_state} purchase cannot be resurrected",
                        purchase_id=existing["id"], lifecycle_state=stored_state,
                    )
                return GoogleEntitlementResult(
                    "not_active", f"purchase is {stored_state}",
                    purchase_id=existing["id"], lifecycle_state=stored_state,
                )
            # Soft-terminal 'expired': only strictly-newer active supersedes.
            if stored_state == "expired" and entitled and signed_ms <= stored_signed:
                return GoogleEntitlementResult(
                    "stale", "stale active cannot resurrect an expired purchase",
                    purchase_id=existing["id"], lifecycle_state="expired",
                )
            # Generic out-of-order guard: ignore strictly-older non-terminal
            # evidence. A hard-terminal event always applies (safety wins).
            if signed_ms < stored_signed and not hard_terminal:
                return GoogleEntitlementResult(
                    "stale", "older provider evidence ignored",
                    purchase_id=existing["id"], lifecycle_state=stored_state,
                )

        purchase_id = existing["id"] if existing else str(uuid.uuid4())
        effective_signed = max(signed_ms, existing["latest_signed_ms"] or 0) if existing else signed_ms

        if existing is None:
            cur.execute(
                """INSERT INTO provider_purchases
                       (id, provider, original_transaction_id, latest_transaction_id, product_id,
                        environment, ownership_type, app_account_token, lifecycle_state,
                        latest_signed_ms, expires_ms, trial_consumed, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, ?, 'PURCHASED', ?, ?, ?, ?, 0, ?, ?)""",
                (purchase_id, provider, purchase_token, purchase_token, subscription_id,
                 environment, obfuscated_account_id, lifecycle_state,
                 effective_signed, expires_ms, now, now),
            )
        else:
            cur.execute(
                """UPDATE provider_purchases
                      SET product_id = ?, environment = ?,
                          app_account_token = COALESCE(app_account_token, ?),
                          lifecycle_state = ?, latest_signed_ms = ?, expires_ms = ?,
                          updated_at = ?
                    WHERE id = ?""",
                (subscription_id, environment, obfuscated_account_id, lifecycle_state,
                 effective_signed, expires_ms, now, purchase_id),
            )

        # Not entitled -> ensure no grant survives, record the durable state.
        if not entitled:
            self._revoke_grants_for_purchase(cur, purchase_id, now)
            return GoogleEntitlementResult(
                "not_active", f"purchase is {lifecycle_state}",
                purchase_id=purchase_id, lifecycle_state=lifecycle_state,
            )

        # ---- entitled: resolve the beneficiary account ----

        # obfuscatedExternalAccountId, when present, is the authoritative binding.
        if obfuscated_account_id is not None:
            if account_id is not None and obfuscated_account_id != account_id:
                # Authenticated caller trying to claim a token bound to someone
                # else -> deterministic conflict (hostile: token replay across
                # accounts). Never fall through to a first-claim.
                return GoogleEntitlementResult(
                    "conflict", "purchase is bound to a different account",
                    purchase_id=purchase_id, lifecycle_state=lifecycle_state,
                )
            beneficiary = obfuscated_account_id
        elif account_id is not None:
            # Tokenless (no obfuscated id): first authenticated claimant wins the
            # lineage via the shared UNIQUE lock; a later different account 409s.
            cur.execute(
                "SELECT * FROM legacy_claims WHERE provider = ? AND original_transaction_id = ?",
                (provider, purchase_token),
            )
            claim = cur.fetchone()
            if claim is None:
                try:
                    cur.execute(
                        """INSERT INTO legacy_claims
                               (id, provider, original_transaction_id, claimant_account_id,
                                evidence_key, result, claimed_at)
                             VALUES (?, ?, ?, ?, ?, 'granted', ?)""",
                        (str(uuid.uuid4()), provider, purchase_token, account_id, purchase_token, now),
                    )
                except sqlite3.IntegrityError:
                    cur.execute(
                        "SELECT * FROM legacy_claims WHERE provider = ? AND original_transaction_id = ?",
                        (provider, purchase_token),
                    )
                    claim = cur.fetchone()
            if claim is not None and claim["claimant_account_id"] != account_id:
                return GoogleEntitlementResult(
                    "conflict", "purchase already claimed by another account",
                    purchase_id=purchase_id, lifecycle_state=lifecycle_state,
                )
            beneficiary = account_id
        else:
            # RTDN (no caller) with no provable beneficiary. If the lineage
            # already has a grant, we've already reactivated it below; otherwise
            # record it 'unbound' and wait for an authenticated sync to bind it —
            # never guess who to grant.
            cur.execute(
                "SELECT account_id FROM entitlement_grants WHERE purchase_id = ? AND state = 'active' LIMIT 1",
                (purchase_id,),
            )
            existing_grant = cur.fetchone()
            if existing_grant is None:
                # Reactivate any previously-revoked grant on this lineage (e.g. an
                # on-hold recovery arriving before the client re-syncs).
                cur.execute(
                    "SELECT account_id FROM entitlement_grants WHERE purchase_id = ? LIMIT 1",
                    (purchase_id,),
                )
                prior = cur.fetchone()
                if prior is None:
                    return GoogleEntitlementResult(
                        "unbound", "no resolvable beneficiary for this purchase yet",
                        purchase_id=purchase_id, lifecycle_state=lifecycle_state,
                    )
                beneficiary = prior["account_id"]
            else:
                beneficiary = existing_grant["account_id"]

        # Never grant to an account that does not exist. On the RTDN path an
        # obfuscatedExternalAccountId is attacker/garbage-influenced; binding a
        # grant to a non-account would both violate the FK and grant nothing
        # useful. Record it unbound and wait for an authenticated sync instead.
        if not _account_exists(cur, beneficiary):
            return GoogleEntitlementResult(
                "unbound", "beneficiary account does not exist",
                purchase_id=purchase_id, lifecycle_state=lifecycle_state,
            )

        # Replacement continuity (contract §3): mutate OLD only after every NEW
        # acceptance guard above has passed (terminal/staleness, ownership,
        # beneficiary resolution, and account existence). The surrounding
        # transaction then makes OLD revoke + NEW grant atomic: any grant error
        # rolls both lineages back.
        if (
            linked_purchase_token
            and linked_purchase_token != purchase_token
            and old is not None
            and old["lifecycle_state"] not in _GOOGLE_HARD_TERMINAL
        ):
            cur.execute(
                "UPDATE provider_purchases SET lifecycle_state = 'replaced', updated_at = ? WHERE id = ?",
                (now, old["id"]),
            )
            self._revoke_grants_for_purchase(cur, old["id"], now)

        self._upsert_grant(cur, purchase_id, beneficiary, "direct", expires_ms, now)

        ack_pending = False
        if not acknowledged:
            self._record_ack_op(cur, provider, purchase_token, beneficiary, now)
            ack_pending = True
        return GoogleEntitlementResult(
            "granted", purchase_id=purchase_id, lifecycle_state=lifecycle_state,
            acknowledge_pending=ack_pending,
        )

    def _record_ack_op(self, cur, provider, purchase_token, account_id, now) -> None:
        """Record a durable, retriable 'acknowledge' op. Acknowledgement is only
        ever recorded AFTER a successful ownership binding + grant (contract §5),
        and a transient failure to acknowledge never erases the entitlement."""
        with contextlib.suppress(sqlite3.IntegrityError):
            cur.execute(
                """INSERT INTO provider_operations
                       (id, provider, op_kind, original_transaction_id, account_id,
                        state, attempts, created_at, updated_at)
                     VALUES (?, ?, 'acknowledge', ?, ?, 'pending', 0, ?, ?)""",
                (str(uuid.uuid4()), provider, purchase_token, account_id, now, now),
            )

    def list_pending_google_acknowledgements(self, provider: str = "google") -> list[dict]:
        """Pending/failed acknowledge ops joined to their purchase so a drainer
        has the (subscription_id, purchase_token) the Developer API needs. Only
        lineages still holding an active grant are acknowledged — a purchase that
        was revoked before we could acknowledge is dropped, not acknowledged."""

        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT o.id AS op_id,
                          o.original_transaction_id AS purchase_token,
                          p.product_id AS subscription_id,
                          p.lifecycle_state AS lifecycle_state
                     FROM provider_operations o
                     JOIN provider_purchases p
                       ON p.provider = o.provider
                      AND p.original_transaction_id = o.original_transaction_id
                    WHERE o.provider = ? AND o.op_kind = 'acknowledge'
                      AND o.state IN ('pending', 'failed')""",
                (provider,),
            )
            return [dict(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def mark_provider_operation(self, op_id: str, *, state: str, error: Optional[str] = None) -> None:
        """Advance a durable provider op's retry state (shared by Apple's
        Set-App-Account-Token and Google's acknowledge ops)."""

        def _do() -> None:
            self._conn.execute(
                "UPDATE provider_operations SET state = ?, attempts = attempts + 1, "
                "last_error = ?, updated_at = ? WHERE id = ?",
                (state, error, _now_iso(), op_id),
            )

        self._run(_do).result()

    def list_unresolved_events(self, provider: str = "apple") -> list[dict]:
        """Durable, non-destructive events awaiting provider reconciliation
        (e.g. tokenless family revokes). Support-visible; never auto-applied."""
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM provider_unresolved_events WHERE provider = ? ORDER BY created_at",
                (provider,),
            )
            return [dict(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def account_entitlement_active(self, account_id: str) -> bool:
        def _do() -> bool:
            cur = self._conn.cursor()
            return _account_has_active_grant(cur, account_id)

        return self._run(_do).result()

    # ---- outbound Set-App-Account-Token reconciliation (retry state) ----

    def list_pending_set_token_operations(self, provider: str = "apple") -> list[dict]:
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM provider_operations WHERE provider = ? "
                "AND op_kind = 'set_app_account_token' AND state IN ('pending', 'failed')",
                (provider,),
            )
            return [dict(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def mark_set_token_operation(self, op_id: str, *, state: str, error: Optional[str] = None) -> None:
        def _do() -> None:
            self._conn.execute(
                "UPDATE provider_operations SET state = ?, attempts = attempts + 1, "
                "last_error = ?, updated_at = ? WHERE id = ?",
                (state, error, _now_iso(), op_id),
            )

        self._run(_do).result()

    def get_set_token_operation(
        self, original_transaction_id: str, provider: str = "apple"
    ) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM provider_operations WHERE provider = ? AND op_kind = 'set_app_account_token' "
                "AND original_transaction_id = ?",
                (provider, original_transaction_id),
            )
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()

    # ---- entitlement read helpers (support-visible durable records) ----

    def get_provider_purchase(
        self, original_transaction_id: str, provider: str = "apple"
    ) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM provider_purchases WHERE provider = ? AND original_transaction_id = ?",
                (provider, original_transaction_id),
            )
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()

    def list_entitlement_grants(self, account_id: str) -> list[dict]:
        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute("SELECT * FROM entitlement_grants WHERE account_id = ?", (account_id,))
            return [dict(r) for r in cur.fetchall()]

        return self._run(_do).result()

    def list_account_payment_history(self, account_id: str) -> list[dict]:
        """The account's billing timeline: every entitlement grant this account
        holds, joined to the store purchase that backs it, newest first.

        Owner-scoped by ``account_id`` (the caller's own account — there is no
        cross-account read). It deliberately exposes NO raw provider or
        transaction identifiers (no ``original_transaction_id``, no Stripe
        subscription id): only the opaque grant id plus the catalog product,
        ownership, lifecycle and timestamps a person needs to understand their
        own billing. A store purchase never appears here unless it produced a
        grant to THIS account, so a family beneficiary sees their access grant
        without seeing the purchaser's ownership lineage.
        """

        def _do() -> list[dict]:
            cur = self._conn.cursor()
            cur.execute(
                """SELECT g.id            AS id,
                          g.grant_kind    AS grant_kind,
                          g.state         AS entitlement_state,
                          g.effective_at  AS effective_at,
                          g.expires_at    AS expires_at,
                          g.revoked_at    AS revoked_at,
                          g.created_at    AS created_at,
                          g.updated_at    AS updated_at,
                          p.provider      AS provider,
                          p.product_id    AS product_id,
                          p.ownership_type AS ownership_type,
                          p.environment   AS environment,
                          p.lifecycle_state AS purchase_state,
                          p.amount_minor  AS amount_minor,
                          p.currency      AS currency,
                          p.trial_consumed AS trial_consumed
                     FROM entitlement_grants g
                     JOIN provider_purchases p ON p.id = g.purchase_id
                    WHERE g.account_id = ?
                    ORDER BY g.created_at DESC, g.id DESC""",
                (account_id,),
            )
            now = _now_iso()
            rows: list[dict] = []
            for r in cur.fetchall():
                d = dict(r)
                # ``is_current`` is the projection a client should render as the
                # live badge: an active grant that has not lapsed. It mirrors the
                # entitlement rule in ``_account_has_active_grant`` (lexical ISO
                # UTC compare) so the timeline and the paywall never disagree.
                d["is_current"] = bool(
                    d.get("entitlement_state") == "active"
                    and (not d.get("expires_at") or d["expires_at"] > now)
                )
                d["trial_consumed"] = bool(d.get("trial_consumed"))
                rows.append(d)
            return rows

        return self._run(_do).result()

    def get_legacy_claim(
        self, original_transaction_id: str, provider: str = "apple"
    ) -> Optional[dict]:
        def _do() -> Optional[dict]:
            cur = self._conn.cursor()
            cur.execute(
                "SELECT * FROM legacy_claims WHERE provider = ? AND original_transaction_id = ?",
                (provider, original_transaction_id),
            )
            row = cur.fetchone()
            return dict(row) if row else None

        return self._run(_do).result()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _row_to_user(row: sqlite3.Row | dict) -> User:
    d = dict(row)
    return User(
        device_id=d["device_id"],
        api_token=d["api_token"],
        plan=d.get("plan") or "free",
        stripe_customer_id=d.get("stripe_customer_id"),
        stripe_subscription_id=d.get("stripe_subscription_id"),
        subscription_status=d.get("subscription_status"),
        subscription_renews_at=d.get("subscription_renews_at"),
        daily_count=d.get("daily_count") or 0,
        daily_day=d.get("daily_day"),
        created_at=d.get("created_at") or "",
        updated_at=d.get("updated_at") or "",
        coupon_pro_expires_at=d.get("coupon_pro_expires_at"),
        account_id=d.get("account_id"),
    )


def _row_to_account(row: sqlite3.Row | dict) -> Account:
    d = dict(row)
    return Account(
        id=d["id"],
        apple_sub=d.get("apple_sub"),
        google_sub=d.get("google_sub"),
        email=d.get("email"),
        plan=d.get("plan") or "free",
        stripe_customer_id=d.get("stripe_customer_id"),
        stripe_subscription_id=d.get("stripe_subscription_id"),
        subscription_status=d.get("subscription_status"),
        subscription_renews_at=d.get("subscription_renews_at"),
        coupon_pro_expires_at=d.get("coupon_pro_expires_at"),
        created_at=d.get("created_at") or "",
        updated_at=d.get("updated_at") or "",
        daily_count=d.get("daily_count") or 0,
        daily_day=d.get("daily_day"),
        supabase_sub=d.get("supabase_sub"),
        deleted_at=d.get("deleted_at"),
        email_normalized=d.get("email_normalized"),
        email_verified_at=d.get("email_verified_at"),
    )


def normalize_email(raw: Optional[str]) -> Optional[str]:
    """Store-side wrapper over ``email_identity.normalize_email``.

    One normalization rule for the whole server: the strict implementation
    (NFKC, bounded lengths, dots and ``+`` tags preserved) lives in
    ``email_identity`` and is shared with the request layer, so a value can
    never be normalized one way at the boundary and another way at the index.

    Returns ``None`` instead of raising, because every caller here is
    already in "is this a usable address?" territory and a soft no keeps the
    SQL paths simple.
    """
    try:
        return email_identity.normalize_email(raw)
    except email_identity.EmailNormalizationError:
        return None


def _row_signed_out(row: sqlite3.Row) -> bool:
    """True when a device row was RETIRED by `sign_out_device`.

    Read defensively via ``keys()``: the column is added by migration, and a
    connection opened against a database that predates it must answer "not
    signed out" rather than raise — an old row is a legacy device, and those
    keep their existing proof requirements.
    """
    try:
        if "signed_out_at" not in row.keys():
            return False
    except AttributeError:
        return False
    return bool(row["signed_out_at"])


def _clean_provider_subject(raw: Optional[str]) -> Optional[str]:
    """Bound an auth-provider subject before it reaches an indexed column.

    The value is opaque to us and comes from outside this process, so it is
    length-bounded and empty-checked rather than trusted. Anything unusable
    becomes ``None``: no claim is strictly better than a malformed one, because
    an unredeemable claim only costs the pre-existing behaviour while a
    malformed key would sit permanently in a unique index.
    """
    if raw is None:
        return None
    value = str(raw).strip()
    return value if 0 < len(value) <= 128 else None


def _row_to_webauthn_credential(row: sqlite3.Row | dict) -> WebAuthnCredential:
    d = dict(row)
    raw_transports = d.get("transports")
    return WebAuthnCredential(
        credential_id=d["credential_id"],
        account_id=d["account_id"],
        public_key=bytes(d["public_key"]),
        sign_count=d.get("sign_count") or 0,
        transports=json.loads(raw_transports) if raw_transports else [],
        nickname=d.get("nickname"),
        created_at=d.get("created_at") or "",
        last_used_at=d.get("last_used_at"),
    )


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _new_device_credential() -> str:
    return secrets.token_urlsafe(48)


def _hash_device_credential(credential: str) -> str:
    return hashlib.sha256(credential.encode("utf-8")).hexdigest()


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def _now_ms() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


def _ms_to_iso(ms: Optional[int]) -> Optional[str]:
    """Convert an Apple epoch-millisecond timestamp to a UTC ISO-8601 string
    (second precision), matching _now_iso() so grant expiry compares correctly."""
    if ms is None:
        return None
    return dt.datetime.fromtimestamp(ms / 1000, tz=dt.timezone.utc).isoformat(timespec="seconds")


def _today_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


def _insert_anonymous_account(cur: sqlite3.Cursor, now: str) -> str:
    """Insert a fresh anonymous account (no provider identity) and return its
    UUID. Caller supplies the cursor so this joins the surrounding transaction."""
    account_id = str(uuid.uuid4())
    cur.execute(
        "INSERT INTO accounts (id, plan, created_at, updated_at) VALUES (?, 'free', ?, ?)",
        (account_id, now, now),
    )
    return account_id


def _purchase_has_active_grant(cur: sqlite3.Cursor, purchase_id: str, account_id: str) -> bool:
    """True when `account_id` holds an active grant on this specific purchase —
    i.e. it is a proven beneficiary/purchaser of this lineage. Used to gate a
    family-scoped revoke so a token that doesn't map to a known beneficiary
    can't cause any mutation (contract §6)."""
    cur.execute(
        "SELECT 1 FROM entitlement_grants WHERE purchase_id = ? AND account_id = ? "
        "AND state = 'active' LIMIT 1",
        (purchase_id, account_id),
    )
    return cur.fetchone() is not None


def _account_exists(cur: sqlite3.Cursor, account_id: Optional[str]) -> bool:
    """True when `account_id` names a real account row. Gates provider grants so
    a garbage/attacker-supplied obfuscatedExternalAccountId can never bind."""
    if not account_id:
        return False
    cur.execute("SELECT 1 FROM accounts WHERE id = ? LIMIT 1", (account_id,))
    return cur.fetchone() is not None


def _account_has_active_grant(cur: sqlite3.Cursor, account_id: str) -> bool:
    """True when the account holds at least one active, unexpired entitlement
    grant. `expires_at` is an ISO string comparable lexicographically against
    _now_iso() (both are UTC, second precision)."""
    cur.execute(
        """SELECT 1 FROM entitlement_grants
              WHERE account_id = ? AND state = 'active'
                AND (expires_at IS NULL OR expires_at > ?)
              LIMIT 1""",
        (account_id, _now_iso()),
    )
    return cur.fetchone() is not None


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------


_store: Optional[Store] = None
_store_lock = threading.Lock()

# Render mounts a persistent disk at /data for srv-d9gg8ngk1i2s738lngd0.
# A DB written anywhere else on Render (the default "./tono.db" in the
# container's ephemeral filesystem, or any path outside /data) is silently
# wiped on every deploy/restart — every device row, account, and Stripe
# linkage lost. That is a data-loss trap, not a soft config warning.
_RENDER_PERSISTENT_ROOT = "/data"


class EphemeralDatabasePathError(RuntimeError):
    """Raised on Render when TONO_DB_PATH is unset or points outside the
    persistent /data disk — where SQLite would be wiped on every deploy."""


def _is_render() -> bool:
    """Render injects RENDER=true into every service's environment. We treat
    any truthy value as "running on Render" so the fail-closed guard cannot be
    defeated by a lowercase/quoted value."""
    return (os.environ.get("RENDER", "") or "").strip().lower() in {"true", "1", "yes"}


def resolve_db_path() -> str:
    """Resolve the SQLite path, failing CLOSED on Render (G-1).

    On Render (``RENDER`` truthy), production MUST write to the persistent
    ``/data`` disk. We reject a missing ``TONO_DB_PATH`` and any resolved path
    outside ``/data`` rather than silently opening an ephemeral DB that is
    wiped on the next deploy. Off Render (local/dev/test), the historical
    ``./tono.db`` default is preserved unchanged.
    """
    raw = os.environ.get("TONO_DB_PATH")

    if not _is_render():
        # Local/dev/test: preserve the long-standing default exactly.
        return raw if raw else "./tono.db"

    # --- Render: fail closed ---
    if not raw or not raw.strip():
        raise EphemeralDatabasePathError(
            "TONO_DB_PATH is unset on Render. Production must write SQLite to the "
            f"persistent disk at {_RENDER_PERSISTENT_ROOT} (e.g. {_RENDER_PERSISTENT_ROOT}/tono.db); "
            "an unset path would open an ephemeral DB that is wiped on every deploy."
        )
    # Normalize to an absolute, symlink-free path and require containment in
    # /data. ``os.path.realpath`` collapses ``..`` and symlink escapes so a
    # value like ``/data/../tmp/x`` cannot slip past the containment check.
    resolved = os.path.realpath(raw)
    persistent_root = os.path.realpath(_RENDER_PERSISTENT_ROOT)
    if resolved != persistent_root and not resolved.startswith(persistent_root + os.sep):
        raise EphemeralDatabasePathError(
            f"TONO_DB_PATH={raw!r} resolves to {resolved!r}, which is outside the "
            f"persistent disk at {persistent_root} on Render. SQLite there would be "
            "wiped on every deploy. Set TONO_DB_PATH to a path under "
            f"{persistent_root} (e.g. {persistent_root}/tono.db)."
        )
    return raw


def get_store() -> Store:
    global _store
    if _store is None:
        with _store_lock:
            if _store is None:
                path = resolve_db_path()
                _store = Store(path)
    return _store


def reset_store() -> None:
    global _store
    if _store is not None:
        with contextlib.suppress(Exception):
            _store.close()
    _store = None
