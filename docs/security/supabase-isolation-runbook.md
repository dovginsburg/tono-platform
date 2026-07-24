# Tono Supabase isolation and auth cutover

## Confirmed starting risk

The former web rewrite targeted a project ref that also appears in ParentScript OAuth evidence. This is a confirmed shared-tenant dependency, not merely an unproven possibility. The hard-coded ref has been removed; Tono now accepts only an environment-selected project URL whose staging and production refs differ.

Do not paste project refs, API keys, user exports, emails, or tokens into source control, tickets, or this runbook.

## Source-controlled controls

- `supabase/config.toml` defines the local project.
- `supabase/migrations/20260713000001_tono_auth_isolation.sql` creates the private identity-link/rollback ledger, enables and forces RLS, and removes all browser-role privileges.
- `supabase/tests/private_roles.sql` must return zero rows.
- `apps/web/src/lib/supabase-deployment.cjs` fails closed for partial, shared, or environment-mismatched deployment configuration.
- `scripts/supabase-auth-migrate.cjs` exports only minimum identity fields, creates unconfirmed target users that must reauthenticate, and rolls back only target IDs captured by the import manifest.

## Dov/device-presence gate

These steps change external accounts and must not be run unattended:

1. In the Supabase dashboard, inventory the current shared project using `docs/security/supabase-control-plane-inventory.md`; do not copy values into the file.
2. Create two projects in the Tono-owned organization: one staging and one production. Verify neither project ref is used by ParentScript.
3. Configure exact URLs only:
   - staging site URL: the approved Tono staging origin under `/app`
   - staging callbacks: the same staging origin under `/app/auth/callback`
   - production site URL: `https://tonoit.com/app`
   - production callback: `https://tonoit.com/app/auth/callback`
   Remove localhost and preview wildcards from production.
4. Link each project locally one at a time and apply migrations from this repository. Never link the repository to the old shared project.
5. Run `supabase/tests/private_roles.sql` in each project's SQL editor. Zero returned rows is the pass condition.
6. Install each project's URL and anonymous key only in its matching Vercel environment, plus `TONO_DEPLOYMENT_ENV` and both expected refs. The Next.js configuration invokes the fail-closed deployment validator during every build.

## Identity migration rehearsal

Run on staging first with a small approved canary cohort. Service-role keys stay in ephemeral shell environment variables and are never written to files.

1. Use `exportUsers()` from `scripts/supabase-auth-migrate.cjs` against the source project. Write the returned JSON to an ignored directory with mode `0600`.
2. Generate a plan with `planReauthentication()`. It refuses identical source/target refs.
3. Use `importUsers()` against Tono staging. Imported users are deliberately unconfirmed and marked `tono_reauthentication_required`; password hashes and OAuth refresh tokens are never copied.
4. Have each canary reauthenticate through the new project's email/OAuth flow, then link the new Supabase user ID to the canonical Tono backend account using the private ledger.
5. Verify sign-in, sign-out, refresh, callback, and backend account continuity.
6. Exercise `rollbackUsers()` with the exact `created_target_user_ids` manifest. It deletes only users created during the rehearsal. Confirm the old shared-project login still works during the rollback window.
7. Repeat the import, reauthenticate the canary, then schedule production cutover. Keep the old tenant read-only for the approved rollback window; do not dual-write auth state.

## Release gates

- Staging and production refs are distinct and neither occurs in ParentScript configuration.
- The web build rejects a mismatched environment/project pair.
- Browser roles have no schema or table privileges on `tono_private` and no RLS policies grant access.
- A real canary export/import/reauthentication/rollback has succeeded in staging.
- Production keys and redirect URIs were reviewed in the dashboard with Dov present.
- Sherlock independently executes the child QA cards before this finding closes.
