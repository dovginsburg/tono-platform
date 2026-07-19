# Rollback notes — tonoit-release-control-v4

## Blast radius: zero

This package is additive and imported by nothing. It touches no lockfile,
deployment, runtime, schema, DNS, store, billing, provider, or credential. There
is no migration, no generated artifact, and no wiring to unwind.

## Full rollback

Because the entire change is confined to `packages/tonoit-release-control-v4/`,
rollback is a single-commit revert:

```bash
git revert <this-commit-sha>
# or, to delete the directory outright on a follow-up branch:
git rm -r packages/tonoit-release-control-v4
```

Either operation is safe: no other code references the package, so removing it
cannot break imports, builds, or tests elsewhere.

## Verifying the rollback

```bash
# 1. Nothing in the tree imports the package.
grep -rN "tonoit_release_control_v4" --include='*.py' . | grep -v packages/tonoit-release-control-v4

# 2. Baseline backend suite behaves exactly as before (unaffected either way).
cd apps/backend && python3 -m pytest -q
```

Expected: the grep prints nothing after `git rm`, and the backend suite result is
identical to baseline (this package never participated in it).

## Partial rollback

Not applicable — the package is self-contained. There are no feature flags,
env vars, or config toggles introduced by this change.
