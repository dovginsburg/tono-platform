-- Build 114 remediation — three columns the registration record was missing.
--
-- Written as a SEPARATE additive migration rather than an edit to
-- 20260726000001, deliberately. That migration uses `create table if not
-- exists`, so editing it in place would be a silent no-op anywhere it had
-- already run, and the columns below would never appear. `add column if not
-- exists` is correct whether the base migration landed an hour ago or has not
-- landed at all.
--
-- Nothing here drops, renames, narrows, or backfills. Every column is nullable
-- with no default, so existing rows stay valid and a rollback is a drop of
-- three columns that nothing outside this build reads.
--
-- ---------------------------------------------------------------------------
-- Why each column exists
-- ---------------------------------------------------------------------------
--
-- `provider_subject` — the auth provider's own id for the user a registration
--   created, recorded BEFORE the address is verified.
--
--   The anonymous upgrade rests entirely on this. A person confirms their
--   address by tapping a link in their mail app, which opens a BROWSER: a
--   client that has never seen them and carries no device bearer, so nothing
--   in its request can say which canonical account started the registration.
--   Without a claim to resolve, that request could only mint a NEW account —
--   so the account holding the person's history, usage and subscription was
--   abandoned at the exact step both mobile clients instruct ("open the link
--   on this device, then come back and sign in").
--
--   It is an opaque public identifier, not a credential. Holding it grants
--   nothing: it can only be presented inside a provider token that this
--   server verifies cryptographically (issuer, signature, audience) before the
--   claim is ever consulted.
--
-- `last_seen_surface` / `last_seen_app_build` — where this person most
--   recently appeared, from a caller that PROVED which account it was acting
--   for.
--
--   `source_surface` and `app_build` became immutable registration facts in
--   this build, because a column named "source" that is rewritten on every
--   later event does not mean source, it means most-recent. Recency is still
--   worth having, so it moved here — and it is only written for an attested
--   caller. Resend and reset take no bearer by design (they have to work for
--   someone locked out), which means anyone able to spell an address could
--   otherwise author these fields on a stranger's row.

alter table tono_private.account_registrations
  add column if not exists provider_subject text;

alter table tono_private.account_registrations
  add column if not exists last_seen_surface text;

alter table tono_private.account_registrations
  add column if not exists last_seen_app_build text;

-- A provider subject backs exactly ONE canonical registration, so a claim can
-- never resolve ambiguously into a merge of two people. Partial, so the
-- overwhelmingly common NULL case stays unconstrained and rows that predate
-- this migration need no backfill.
create unique index if not exists tono_account_registrations_provider_subject
  on tono_private.account_registrations (provider_subject)
  where provider_subject is not null;

-- The same clamp `source_surface` already carries, for the same reason: this
-- value is read back by the registration report, so an unbounded client string
-- must not be storable here.
alter table tono_private.account_registrations
  drop constraint if exists tono_account_registrations_last_seen_surface_check;

alter table tono_private.account_registrations
  add constraint tono_account_registrations_last_seen_surface_check
  check (last_seen_surface is null
         or last_seen_surface in ('web', 'ios', 'android', 'unknown'));

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- ROLLBACK
-- ---------------------------------------------------------------------------
-- Additive only, so rolling back cannot damage existing data. Reverse order:
--
--   alter table tono_private.account_registrations
--     drop constraint if exists tono_account_registrations_last_seen_surface_check;
--   drop index if exists tono_private.tono_account_registrations_provider_subject;
--   alter table tono_private.account_registrations
--     drop column if exists last_seen_app_build;
--   alter table tono_private.account_registrations
--     drop column if exists last_seen_surface;
--   alter table tono_private.account_registrations
--     drop column if exists provider_subject;
--   notify pgrst, 'reload schema';
--
-- Effect of rollback: the verification click stops being able to resolve back
-- to the account that started a registration, so the pre-remediation
-- account-orphaning behaviour returns for any registration begun after the
-- rollback. No account, identity, entitlement or audit row is lost — RLS
-- posture, policies and the two tables themselves are untouched by this
-- migration and therefore by its reversal.
