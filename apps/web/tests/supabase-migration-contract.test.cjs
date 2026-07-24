const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const migrationPath = path.join(__dirname, '../../../supabase/migrations/20260713000001_tono_auth_isolation.sql');
const sql = fs.readFileSync(migrationPath, 'utf8').toLowerCase();

test('private auth migration denies browser roles at schema and table layers', () => {
  assert.match(sql, /revoke all on schema tono_private from public, anon, authenticated/);
  assert.match(sql, /revoke all on all tables in schema tono_private from public, anon, authenticated/);
  assert.match(sql, /alter table tono_private\.identity_links enable row level security/);
  assert.match(sql, /alter table tono_private\.identity_links force row level security/);
});

test('identity link migration has rollback-safe source and target identifiers', () => {
  assert.match(sql, /source_project_ref text not null/);
  assert.match(sql, /source_user_id uuid not null/);
  assert.match(sql, /target_user_id uuid/);
  assert.match(sql, /migration_run_id uuid not null/);
  assert.match(sql, /unique \(source_project_ref, source_user_id\)/);
});

test('migration records ownership and reloads PostgREST', () => {
  assert.match(sql, /comment on schema tono_private is 'tono-owned/);
  assert.match(sql, /notify pgrst, 'reload schema'/);
});
