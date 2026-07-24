-- Tono-owned auth migration metadata. Browser-facing roles have no access.
create schema if not exists tono_private authorization postgres;
comment on schema tono_private is 'Tono-owned private auth and identity migration state; never exposed to browser roles';

revoke all on schema tono_private from public, anon, authenticated;
grant usage on schema tono_private to service_role;

create table if not exists tono_private.auth_migration_runs (
  id uuid primary key default gen_random_uuid(),
  source_project_ref text not null,
  target_project_ref text not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  rolled_back_at timestamptz,
  constraint tono_distinct_projects check (source_project_ref <> target_project_ref)
);

create table if not exists tono_private.identity_links (
  id uuid primary key default gen_random_uuid(),
  migration_run_id uuid not null references tono_private.auth_migration_runs(id) on delete cascade,
  source_project_ref text not null,
  source_user_id uuid not null,
  target_user_id uuid references auth.users(id) on delete set null,
  identity_provider text not null default 'email',
  state text not null default 'planned' check (state in ('planned', 'created', 'reauthenticated', 'rolled_back')),
  created_at timestamptz not null default now(),
  reauthenticated_at timestamptz,
  rolled_back_at timestamptz,
  unique (source_project_ref, source_user_id)
);

comment on table tono_private.auth_migration_runs is 'Tono auth cutover and rollback audit ledger';
comment on table tono_private.identity_links is 'Tono source-to-target identity links; contains identifiers but no passwords, tokens, or key material';

alter table tono_private.auth_migration_runs enable row level security;
alter table tono_private.auth_migration_runs force row level security;
alter table tono_private.identity_links enable row level security;
alter table tono_private.identity_links force row level security;

revoke all on all tables in schema tono_private from public, anon, authenticated;
revoke all on all sequences in schema tono_private from public, anon, authenticated;
revoke all on all functions in schema tono_private from public, anon, authenticated;
grant select, insert, update, delete on all tables in schema tono_private to service_role;
grant usage, select on all sequences in schema tono_private to service_role;

alter default privileges for role postgres in schema tono_private revoke all on tables from public, anon, authenticated;
alter default privileges for role postgres in schema tono_private revoke all on sequences from public, anon, authenticated;
alter default privileges for role postgres in schema tono_private revoke all on functions from public, anon, authenticated;
alter default privileges for role postgres in schema tono_private grant select, insert, update, delete on tables to service_role;
alter default privileges for role postgres in schema tono_private grant usage, select on sequences to service_role;

notify pgrst, 'reload schema';
