# Canonical remote and release provenance

## Source authority

The only canonical source remote is `https://github.com/dovginsburg/tono-platform`.

Canonical deploys must resolve to a full 40-character commit on `main`. Provider dashboard deploy buttons and deploys from a developer checkout are not release paths. The staging workflow checks out the requested SHA in GitHub Actions, proves it is reachable from `origin/main`, generates provenance, builds the artifacts, and records provider deployment handles.

The GitHub repository previously contained an unrelated legacy monorepo. Its final `main` commit (`b4e1ff5c5f662291cee3c5cdf2a4ea37fb79eab5`) is preserved as both:

- branch `legacy/pre-canonical-main`
- annotated tag `legacy-remote-main-2026-07-08`

The canonical imported-history decisions and original-to-canonical commit mappings remain in `docs/provenance/history-map.json`. Before publication, the canonical history was rewritten once to remove every historical `node_modules` path, including a 109.64 MB generated Next.js SWC binary rejected by GitHub. The target side of each provenance map was composed through that rewrite; original source SHAs remain unchanged.

## Runtime provenance contract

Every artifact receives the same deterministic payload:

```json
{
  "canonical_sha": "<40-character Git SHA>",
  "contract_sha256": "<SHA-256 of packages/contracts/openapi.json>",
  "schema_revision": "<contents of schema/revision.txt>"
}
```

Generation is centralized in `scripts/ci/prepare_provenance.py`. The web artifact serves it as `/build-provenance.json`; the API serves the same path with an immutable cache policy. Backend OCI labels carry all three values.

## Staging configuration

GitHub environment `staging` must contain:

Secrets:

- `VERCEL_TOKEN`
- `VERCEL_ORG_ID`
- `VERCEL_PROJECT_ID` (the Vercel project rooted at `apps/web`)
- `RAILWAY_TOKEN`

Variables:

- `RAILWAY_PROJECT_ID`
- `RAILWAY_STAGING_ENVIRONMENT`
- `RAILWAY_BACKEND_SERVICE` (the Railway service rooted at `apps/backend`)

Staging must use distinct data, auth, and payment credentials. Never copy production values into the `staging` environment.

## Deploy by immutable SHA

Run `.github/workflows/deploy-staging.yml` with a full SHA from canonical `main`. The run:

1. proves the checkout equals the requested SHA and is reachable from `origin/main`;
2. regenerates source/contract/schema provenance;
3. builds the web bundle and labeled backend image;
4. uploads both artifacts plus SHA-256 checksums;
5. creates a non-production Vercel deployment and a Railway staging deployment;
6. stores `deployment-record.json` with the immutable artifact checksums and provider rollback handles.

A release is invalid if either provider's `/build-provenance.json` differs from `build/release-manifest.json`.

## Rollback

Download `tono-staging-deployment-record-<sha>` from the successful GitHub Actions run. Roll back by promoting/redeploying the exact Vercel deployment URL and Railway deployment ID recorded there. Do not rebuild an old branch or deploy a local checkout: that produces a new artifact and is not a rollback.
