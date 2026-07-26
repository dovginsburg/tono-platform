// Build 114 — the email registration migration's security posture, asserted
// against the SQL that actually ships rather than a description of it.
//
// These are the properties a hostile reader would attack first: a browser role
// reaching the audit trail, RLS enabled but not forced (so the owner bypasses
// it), a unique constraint that merges two people onto one address, or a
// secret-shaped column creeping into an event row.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const migrationPath = path.join(
  __dirname,
  '../../../supabase/migrations/20260726000001_tono_email_registration.sql'
);
const raw = fs.readFileSync(migrationPath, 'utf8');
const sql = raw.toLowerCase();

test('registration tables live in the private schema browser roles cannot use', () => {
  assert.match(sql, /create table if not exists tono_private\.account_registrations/);
  assert.match(sql, /create table if not exists tono_private\.account_registration_events/);
  assert.match(sql, /revoke all on tono_private\.account_registrations from public, anon, authenticated/);
  assert.match(
    sql,
    /revoke all on tono_private\.account_registration_events from public, anon, authenticated/
  );
});

test('RLS is enabled AND forced on both tables', () => {
  for (const table of ['account_registrations', 'account_registration_events']) {
    assert.match(
      sql,
      new RegExp(`alter table tono_private\\.${table} enable row level security`),
      `${table} must enable RLS`
    );
    assert.match(
      sql,
      new RegExp(`alter table tono_private\\.${table} force row level security`),
      `${table} must FORCE RLS — without it the owner silently bypasses every policy`
    );
  }
});

test('only service_role gets a policy; anon/authenticated get none', () => {
  assert.match(sql, /create policy tono_registrations_service_role[\s\S]*?to service_role/);
  assert.match(sql, /create policy tono_registration_events_service_role[\s\S]*?to service_role/);
  // The absence of a permissive browser-role policy is the control. If someone
  // ever adds one, this fails.
  assert.doesNotMatch(sql, /create policy[\s\S]*?\bto\s+(anon|authenticated)\b/);
});

test('a verified address backs exactly one canonical account', () => {
  assert.match(
    sql,
    /create unique index if not exists tono_account_registrations_verified_email/
  );
  // Partial: pending rows may share an address; only verification claims it.
  assert.match(sql, /where lifecycle_state = 'verified' and email_normalized is not null/);
});

test('the canonical principal is the account id, never the email', () => {
  assert.match(sql, /account_id\s+uuid primary key/);
  assert.doesNotMatch(sql, /email\w*\s+text primary key/);
});

test('lifecycle state is constrained to the three product states', () => {
  assert.match(sql, /check \(lifecycle_state in \('pending', 'verified', 'disabled'\)\)/);
});

test('no secret-shaped column exists in either table', () => {
  // Scope the scan to the CREATE TABLE bodies so prose in comments (which
  // legitimately says "never a password") cannot mask a real column.
  const bodies = raw.match(/create table if not exists tono_private\.[\s\S]*?\n\);/g) || [];
  assert.equal(bodies.length, 2, 'expected exactly two created tables');
  const forbidden = [
    'password',
    'passwd',
    'secret',
    'access_token',
    'refresh_token',
    'session_token',
    'verification_token',
    'reset_token',
    'api_key',
  ];
  for (const body of bodies) {
    const columnLines = body
      .split('\n')
      .filter((line) => !line.trim().startsWith('--'))
      .join('\n')
      .toLowerCase();
    for (const word of forbidden) {
      assert.ok(
        !columnLines.includes(word),
        `a column matching "${word}" must never exist in the registration tables`
      );
    }
  }
});

test('the event table carries no email column at all', () => {
  const eventBody = raw
    .match(/create table if not exists tono_private\.account_registration_events[\s\S]*?\n\);/)[0]
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n')
    .toLowerCase();
  assert.ok(
    !eventBody.includes('email'),
    'the audit stream must not duplicate the address; it lives once on the registration row'
  );
});

test('migration is additive and documents its rollback', () => {
  // Nothing destructive against pre-existing objects. `drop policy if exists`
  // is scoped to this migration's own policies and is required for re-runs.
  assert.doesNotMatch(sql, /drop table (?!if exists tono_private\.account_registration)/);
  assert.doesNotMatch(sql, /alter table (?!tono_private\.account_registration)/);
  assert.doesNotMatch(sql, /drop column/);
  assert.match(sql, /-- rollback/);
  assert.match(sql, /drop table if exists tono_private\.account_registration_events/);
  assert.match(sql, /drop table if exists tono_private\.account_registrations/);
});

test('PostgREST is reloaded so the new grants take effect', () => {
  assert.match(sql, /notify pgrst, 'reload schema'/);
});
