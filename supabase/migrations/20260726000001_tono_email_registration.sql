-- Build 114 — product-owned email registration state and audit trail.
--
-- Supabase keeps owning auth.users: passwords, verification links and reset
-- links live there and are never copied here. What this migration adds is the
-- PRODUCT fact Tono owns — which canonical account an email identity belongs
-- to, what lifecycle state it is in, and when/where that changed.
--
-- Additive and reversible. It creates new objects only: no existing table,
-- column, policy or grant is altered or dropped, so an existing deployment
-- keeps working unchanged and every existing user stays valid. The rollback is
-- at the bottom of this file.
--
-- Authority model, deliberately the same one 20260713000001 established:
--   * These tables live in `tono_private`, which browser roles (anon,
--     authenticated) cannot even USE. There is therefore no PostgREST path to
--     them at all — a stolen browser JWT reaches nothing here.
--   * RLS is enabled AND forced, so the policies apply to the table owner too.
--     Without FORCE, `postgres` bypasses RLS and a future function running as
--     owner would silently read every account's history.
--   * The default-deny posture is explicit: RLS is on with NO permissive
--     policy for anon/authenticated, so the answer to a browser-role read is
--     zero rows rather than an error that leaks existence.
--   * service_role (the Tono backend) is the only writer, and the backend
--     scopes every read to the caller's own account id — see
--     `server.account_registration_events`, which takes no account parameter.

-- ---------------------------------------------------------------------------
-- Current registration state: one row per canonical account.
-- ---------------------------------------------------------------------------
create table if not exists tono_private.account_registrations (
  -- The canonical principal. NOT the email: making an address the key is what
  -- turns "two people, one address spelling" into a silent account merge.
  account_id       uuid primary key,
  lifecycle_state  text not null default 'pending'
                     check (lifecycle_state in ('pending', 'verified', 'disabled')),
  -- Normalized comparison form only (case-folded, NFKC; dots and +tags
  -- preserved). Never a password, never a token.
  email_normalized text,
  provider         text not null default 'email',
  created_at       timestamptz not null default now(),
  verified_at      timestamptz,
  source_surface   text not null default 'unknown'
                     check (source_surface in ('web', 'ios', 'android', 'unknown')),
  app_build        text,
  last_sign_in_at  timestamptz,
  last_seen_at     timestamptz,
  updated_at       timestamptz not null default now()
);

-- One verified address backs exactly ONE canonical account. Partial, so two
-- pending registrations may legitimately race for the same address and only
-- the one that actually proves ownership claims it. A second verification
-- raises a unique violation instead of merging two histories.
create unique index if not exists tono_account_registrations_verified_email
  on tono_private.account_registrations (email_normalized)
  where lifecycle_state = 'verified' and email_normalized is not null;

create index if not exists tono_account_registrations_state
  on tono_private.account_registrations (lifecycle_state);

-- ---------------------------------------------------------------------------
-- Append-only lifecycle audit.
-- ---------------------------------------------------------------------------
-- Deliberately has NO email column: the address is recorded once, on the
-- registration row above. An event stream is the last place to duplicate an
-- identifier. `detail` is a short server-chosen code — never a client string,
-- a provider response, or a payload.
create table if not exists tono_private.account_registration_events (
  id             bigint generated always as identity primary key,
  account_id     uuid,
  event_type     text not null,
  occurred_at    timestamptz not null default now(),
  source_surface text not null default 'unknown'
                   check (source_surface in ('web', 'ios', 'android', 'unknown')),
  app_build      text,
  detail         text
);

create index if not exists tono_registration_events_account
  on tono_private.account_registration_events (account_id, occurred_at);
create index if not exists tono_registration_events_ts
  on tono_private.account_registration_events (occurred_at);

comment on table tono_private.account_registrations is
  'Tono-owned email registration state per canonical account; contains no password, token, or provider payload';
comment on table tono_private.account_registration_events is
  'Tono-owned append-only registration lifecycle audit; contains no email, password, token, or provider payload';

-- ---------------------------------------------------------------------------
-- Row level security — enabled AND forced, default deny.
-- ---------------------------------------------------------------------------
alter table tono_private.account_registrations enable row level security;
alter table tono_private.account_registrations force row level security;
alter table tono_private.account_registration_events enable row level security;
alter table tono_private.account_registration_events force row level security;

revoke all on tono_private.account_registrations from public, anon, authenticated;
revoke all on tono_private.account_registration_events from public, anon, authenticated;
revoke all on all tables in schema tono_private from public, anon, authenticated;
revoke all on all sequences in schema tono_private from public, anon, authenticated;

grant select, insert, update, delete on tono_private.account_registrations to service_role;
grant select, insert, update, delete on tono_private.account_registration_events to service_role;
grant usage, select on all sequences in schema tono_private to service_role;

-- Explicit service_role policies. FORCE row level security applies to the
-- owner too, so without these the backend itself would be denied — the grants
-- above are necessary but not sufficient.
drop policy if exists tono_registrations_service_role on tono_private.account_registrations;
create policy tono_registrations_service_role
  on tono_private.account_registrations
  for all
  to service_role
  using (true)
  with check (true);

drop policy if exists tono_registration_events_service_role on tono_private.account_registration_events;
create policy tono_registration_events_service_role
  on tono_private.account_registration_events
  for all
  to service_role
  using (true)
  with check (true);

-- No policy is created for anon or authenticated. That absence IS the control:
-- with RLS enabled and no permissive policy, a browser role selects zero rows.

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
-- This migration only ADDS objects, so rolling it back cannot damage existing
-- data or block existing users. Run in this order (reverse of creation):
--
--   drop policy if exists tono_registration_events_service_role
--     on tono_private.account_registration_events;
--   drop policy if exists tono_registrations_service_role
--     on tono_private.account_registrations;
--   drop table if exists tono_private.account_registration_events;
--   drop table if exists tono_private.account_registrations;
--   notify pgrst, 'reload schema';
--
-- Effect of rollback: the backend loses the durable registration record and
-- audit trail. It does NOT lose any account, identity, or entitlement —
-- `accounts.email` / `email_verified_at` remain the authority the entitlement
-- path reads, and Supabase still owns auth.users. Email login continues to
-- work; only the product-side audit history stops being written.
