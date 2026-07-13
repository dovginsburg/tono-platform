# Web dependency audit policy

CI runs `npm run audit:prod`, which invokes `npm audit --omit=dev --audit-level=high`.
The web build fails when npm reports a high or critical advisory in the production
dependency tree. Moderate and low advisories remain visible in audit output but do
not block CI; they should be remediated during routine dependency maintenance.

## Exceptions

There are currently no high or critical production-audit exceptions. If an
exception becomes necessary, document the advisory ID, affected package and path,
exposure analysis, compensating controls, owner, and expiration date here. Do not
weaken the audit threshold or suppress an advisory without that review record.

## Current non-blocking advisory

As of 2026-07-13, npm reports GHSA-qx2v-qp2m-jg93 for the copy of PostCSS bundled
inside Next.js 15.5.20. npm rates it moderate, so it is below the CI threshold. It
cannot be independently upgraded because Next.js pins that transitive dependency;
re-check it whenever Next.js is upgraded.