# Protected-app redirect staging and rollback

This runbook applies only to the protected-app redirect change. Production deployment is prohibited under task `t_775dbe73`.

## Provenance-gated staging

1. Use a clean checkout of the reviewed commit; record `git rev-parse HEAD` and require `git status --porcelain` to be empty.
2. Generate provenance with `python3 scripts/ci/prepare_provenance.py` and verify the generated web provenance SHA equals the reviewed commit.
3. Build with the isolated staging Supabase project and `TONO_DEPLOYMENT_ENV=staging`; `npm run verify:supabase-env`, `npm test`, and `npm run build` must pass.
4. Deploy that exact commit to the Vercel Preview environment only. Set `NEXT_PUBLIC_SITE_URL` to the approved preview origin and `VERCEL_ENV=preview`; never alias this task's deployment to `tonoit.com`.
5. Record the Vercel deployment ID, immutable preview URL, reviewed commit SHA, and served `/app/build-provenance.json` SHA before independent QA.

## Rollback

1. Keep the previous known-good staging deployment ID before promotion.
2. If any login, callback, logout, session, provenance, or open-redirect check fails, remove the candidate's staging alias and restore the previous deployment to that alias.
3. Confirm the restored deployment's provenance SHA and repeat no-follow checks for `/app/login` and `/app/app`.
4. Do not roll this candidate forward to production. A separate approved production card must select and deploy a reviewed, independently verified SHA.
