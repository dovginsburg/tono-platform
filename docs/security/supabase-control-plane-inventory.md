# Supabase control-plane inventory (no secret values)

Complete this once per environment from Supabase Dashboard → Project Settings. Store project refs in the deployment secret manager, never in this document.

| Field | Staging | Production |
|---|---|---|
| Supabase organization owner verified | [ ] | [ ] |
| Project name begins with `tono-` | [ ] | [ ] |
| Project ref differs from every ParentScript project | [ ] | [ ] |
| Account holder / billing owner recorded in password manager | [ ] | [ ] |
| Region and database major version recorded | [ ] | [ ] |
| Auth providers inventoried | [ ] | [ ] |
| Site URL is environment-specific | [ ] | [ ] |
| Allowed redirect URIs are environment-specific and exact | [ ] | [ ] |
| Anonymous key installed only in matching Vercel environment | [ ] | [ ] |
| Service-role key installed only in approved server-side migration environment | [ ] | [ ] |
| `supabase db push` applied from this repository | [ ] | [ ] |
| `supabase/tests/private_roles.sql` returns zero rows | [ ] | [ ] |
| Auth export file created mode 0600 outside git | [ ] | [ ] |
| Reauthentication canary completed | [ ] | [ ] |
| Rollback canary completed | [ ] | [ ] |

Owner approval: ____________________  Date: __________
Operator: _________________________  Change ticket: __________
