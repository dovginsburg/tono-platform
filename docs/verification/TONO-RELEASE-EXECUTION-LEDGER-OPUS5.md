# Tono — Release Execution Ledger (Claude Opus 5, single authorized session)

**Candidate:** this commit — the single linear successor to `5d3fdd7e385391d004e758be6ca759e4ff819916`.
(A tracked file cannot cite its own SHA without changing it; the exact HEAD is in
`/tmp/tono-final-masses-opus5-handoff.md` and in `git rev-parse HEAD`.)
**Date:** 2026-07-24 · **Session:** `d96c7bf7-7eed-49f6-b79c-dbd5b673098e`
**Verdict:** executed to the next irreducible protected gate. Every reversible
artifact is sealed and receipted. **Blocked below §7. Not self-approved.**

---

## 1. Request receipt (verbatim)

### Human request — verbatim, controlling execution model

> Yes. For this Tono release, Ezra should directly operate one strong coding session from the current code through deployment and live verification, without routing implementation through Gary. Sherlock/Quinn can independently test the completed artifact, but Ezra remains accountable until every release gate passes.

### Additional human control-loop decision — verbatim

> For now, Ezra should directly launch and supervise one strong Claude Code/Codex session for Tono’s critical path. Gary can handle narrow, isolated tasks, but should not own integrated releases until the workflow proves reliable.
>
> Putting Gary on GPT-5.6 would improve coding quality, but it would not fix rewritten instructions, fragmented ownership, stale progress claims, or missing end-to-end verification. After Gary completes three consecutive scoped jobs with matching request receipts, commits, tests, independent QA, and live proof, he can gradually resume broader coding ownership.

**Honoured:** one session, no subagents, no parallel writers, no routing to Gary,
work confined to the named worktree. Sherlock/Quinn handoff is §5 — read-only,
bound to an immutable object.

---

## 2. Baseline / candidate proof

| | value |
|---|---|
| Session-start anchor (re-verified before any edit) | HEAD `5d3fdd7e385391d004e758be6ca759e4ff819916`, tree `70b0b1417a9f6bac9afc96d59c3ad5b7611d6c84`, sole parent `1464d03d9523c56b25f4ae148031e26b1337f7ed`, status clean, `git fsck` clean |
| One documented linear successor | this commit — **sole parent** `5d3fdd7e…` (parent count 1) |
| Lineage | `1464d03d` → `5d3fdd7e` → **this commit** — strictly linear, no merges |
| Final status | `git status --porcelain` empty |
| Pushed? | **No.** No remote ref contains either commit. |

### Ancestry reconciliation vs `origin/main`

- `origin/main` = `4605b31f…`; candidate is **ahead 2, behind 1**; merge-base `1d3a36fd…`.
- `tree(4605b31f)` == `tree(1d3a36fd)` — main's tip is a **merge commit that adds no
  tree content**, and `1d3a36fd` **is an ancestor of the candidate**.
- ⇒ **The candidate strictly supersedes everything on `origin/main`.** Nothing is lost by
  advancing main to it.
- Local `main` (`08f26d89…`) is stale and unrelated to the release; not used.

---

## 3. Test / build receipts — installed, no-download, no swallowed failures

Run at this commit unless noted.

| Suite | Command | Result |
|---|---|---|
| Backend | `pytest apps/backend/tests` | **586 passed, 1 skipped** |
| API contract | `scripts/ci/export_openapi.py --check` | **matches checked source** |
| Provenance unit | `unittest scripts/ci/test_prepare_provenance.py` | **5 passed** |
| Source hygiene | `scripts/ci/verify_source.py` | **ok — 462 tracked entries, 5 imports verified** |
| Web unit | `npm test` | **31 passed** |
| Web typecheck | `npx tsc --noEmit` | **clean** |
| Web build | `npm run build` (workflow env) | **succeeded** |
| Web prod deps | `npm run audit:prod` | **0 vulnerabilities** |
| iOS build | `xcodebuild build -scheme Tono` | **BUILD SUCCEEDED** (at `5d3fdd7e`; no iOS source changed since) |
| iOS tests | `xcodebuild test -only-testing:TonoTests` | **330 passed, 0 failures** |
| iOS Space-cursor | `SpaceCursorGestureTests` + standalone verifier | **20 tests / 67 checks** |
| iOS verifiers | live-tone privacy / opportunity / shortcut / focused | **299 / 161 / 50 / 151 checks** |
| Android | `./gradlew testDebugUnitTest assembleDebug` | **BUILD SUCCESSFUL, 5 tests, 0 failures** |
| Hostile probes | `test_hostile_release_probes.py` | **63 passed** |

**Not runnable — exact missing prerequisite, not faked:**

- `npm run lint` — no ESLint config committed; `next lint` prompts interactively
  and blocks. CI does not run lint either. Prerequisite: commit an ESLint config
  (or migrate to the ESLint CLI) and wire it into CI.
- `build90_recovery_gate.py`, `verify_build91_entitlement_contract.py` — fail
  closed by design (§7.1).
- `verify_build83.py` / `verify_build85.py` — pin `CFBundleVersion` 83/85; shipping
  is 101. Structurally unpassable; pre-existing at baseline.

---

## 4. Exact-SHA artifacts and provider-context preflight

### Artifacts built at this commit's SHA (local, reversible, nothing published)

| Artifact | Receipt |
|---|---|
| Backend image `tono-backend:<HEAD>` | `sha256:80e7b7f2f1cd835cf1eb0a31b5a534eea3a218f261e019e580d82f8b4873839c` |
| Backend **runtime** binding | container `/health` → `canonical_sha` == HEAD ✅ |
| Web artifact tarball | `sha256:22df6fb3c931b265c76a8e5df18e2e0c746bf182500757552a3aba4176deac16` |
| Web artifact binding | `public/build-provenance.json` → `canonical_sha` == HEAD ✅ + `.next/app-build-manifest.json` present |
| Contract | `contract_sha256 = 694e9918743c3346732a69d859f0763be6926369b97f95d27f440d3f31deae8d` |

### Deployment roots as they actually are

| Surface | Live | In repo |
|---|---|---|
| Web | Vercel `amazed-labs/tono-web` (`prj_jyYHWwI0YUxGCfiQ2ctuJ8gxWvw5`), root `apps/web`, aliases `tonoit.com`, `www.tonoit.com`; live prod deploy `dpl_8iQ4PRgSQLpRf2ukifSZAJigsjF8` serving `canonical_sha 4605b31f` | `apps/web/vercel.json` |
| Backend | **Render** — `rndr-id` / `x-render-origin-server: uvicorn` on `api.tonoit.com`; service `srv-d9gg8ngk1i2s738lngd0` | ⚠️ **no `render.yaml`**; repo carries `railway.toml` + `fly.toml` |
| Staging deploy | `deploy-staging.yml` targets Vercel preview + **Railway** | — |

⚠️ **Deployment-root divergence:** production backend runs on Render, but the
canonical staging workflow deploys the backend to Railway, and the repo has no
infrastructure-as-code for Render. Staging is therefore not platform-representative.
Owner decision; not changed here.

### Live production state (read-only GETs, no mutation)

```
https://tonoit.com/app/build-provenance.json
  canonical_sha = 4605b31f697b01f8e989d136b071f3da3ea090c6   (= origin/main, NOT this candidate)

https://api.tonoit.com/health
  canonical_sha        = "unknown"      ⚠️ live backend is not bound to any source SHA
  stripe_configured    = true
  apple_configured     = false          ⚠️ TONO_APPLE_ROOT_CA_PEM unset
  google_play_configured = false        ⚠️ TONO_GOOGLE_SERVICE_ACCOUNT_JSON unset
```

Per `docs/operations/tono-billing-launch-runbook.md` these names are **required**,
and `apps/backend/app_store.py` states verification is **503 until set — "we never
fake success."** So today a real iOS or Play purchase **cannot be verified
server-side**: the user is charged by the store and the backend grants nothing.
Fail-closed (no false entitlement), but revenue-breaking. See §7.3.

### Release-path defect found and fixed this session

`deploy-staging.yml`'s "Build web artifact" step declared a **partial** Supabase
env, which `next.config.js` rejects (`loadSupabaseDeployment` accepts all-five or
none, and requires a canonical `https://<20-char>.supabase.co` URL). The step threw
`Supabase deployment configuration is incomplete` and the job aborted **before any
deploy step** — the exact-SHA release path could not run at all. Reproduced locally,
fixed, and guarded by `apps/web/src/lib/workflow-build-env.test.ts` (red-capable:
restoring the old env fails tests 3 and 4). Landed in this commit.

---

## 5. Independent read-only QA handoff (Sherlock / Quinn)

Bind to the immutable object — do not re-resolve a branch name:

```
commit <HEAD of this branch — see handoff>
parent 5d3fdd7e385391d004e758be6ca759e4ff819916   (sole)
```

Reproduce, read-only, no provider credentials required:

```bash
git fsck --connectivity-only
git log --oneline -1          # expect this commit
test -z "$(git status --porcelain)"

python3 -m pytest apps/backend/tests -q                 # 586 passed, 1 skipped
python3 scripts/ci/export_openapi.py --check            # contract matches
python3 scripts/ci/verify_source.py                     # 462 tracked entries
cd apps/web && npm ci && npm test && npx tsc --noEmit    # 31 passed, clean
cd apps/ios && xcodebuild test -project Tono.xcodeproj -scheme Tono \
  -destination 'platform=iOS Simulator,name=<any iOS 26 sim>' \
  -only-testing:TonoTests CODE_SIGNING_ALLOWED=NO        # 330 passed
cd apps/android && ./gradlew testDebugUnitTest assembleDebug   # 5 passed
```

Highest-value adversarial targets (all newly changed):
`test_response_cache_isolation.py` (P0 cross-account leak),
`test_portal_customer_resolution.py` (P1 cancel path),
`api-path.test.ts` (P1 web 404s), `next-rewrites.test.ts`,
`workflow-build-env.test.ts`, `SpaceCursorGestureTests`.

---

## 6. Build-90 gate — CLOSED 2026-07-25 by owner attestation

**Closed via Form B over an attested EMPTY population.** Dov Ginsburg attested
that no one has paid for Tono through Stripe, App Store, or Google Play, so no
charged build-90 user exists and no historical entitlement restoration is
required. Recorded in `apps/ios/AppStore/build91_release_readiness.json`;
full record, corroborating evidence, and limits:
`docs/operations/BUILD90-OWNER-ATTESTATION-2026-07-25.md`.

Corroboration captured read-only this session — **consistent with, not a
substitute for, the attestation**: production `/health` shows
`apple_configured=false` and `google_play_configured=false`, and `app_store.py`
returns 503 when unconfigured, so **no App Store or Play purchase was ever
verified or granted by the backend**. The catalog records iOS as `under-review`
and Android as `closed-test` — neither publicly released. `stripe_configured` **is**
true, so the Stripe leg was live and was **not** independently checked; that fact
rests solely on the owner's attestation.

Deliberately NOT claimed: Form A (`checkout_disabled`) stays `supplied: false` —
no App Store Connect observation was made (ASC keys exist on this machine but no
issuer ID does). No provider report was queried. `bounded_window_days = 90` was
**not** stated by the owner; the gate requires a positive integer and the attested
population is empty, so it is a safety net binding no known user.

✅ **Executable verification was run** against this artifact before the closing
commit, with `TONO_BUILD90_RECOVERY_EVIDENCE` confirmed unset so the verdict comes
from the committed artifact:
`build90-recovery-gate: READY (evidence via artifact)` (exit 0) and
`build91-entitlement-contract: PASS` (exit 0) — matching the attestation record's
predicted output exactly. QA should re-run both as an independent reproduction
before any store upload.

---

## 7. Protected gates — BLOCKED, with exact prerequisites

### 7.1 Build-90 charged-before-upgrade — ✅ **CLOSED** (owner attestation, §6)
Both gate scripts executed and pass (READY / PASS, exit 0). Remaining action:
independent QA reproduction of that run. Re-open only if a provider report ever
contradicts the attestation.

### 7.2 Exact-SHA staging preview — **blocked on two prerequisites**
1. **Workflow requires the SHA be an ancestor of `origin/main`**
   (`deploy-staging.yml:51`, `git merge-base --is-ancestor`). The candidate is not
   on main, so the workflow refuses to run. Advancing main is a protected lineage
   action requiring approval.
2. **Vercel `tono-web` has ZERO Preview-scoped env vars** — every variable is
   Production-only. A preview would therefore build with an empty Supabase config
   **and**, at runtime, fall back to `https://api.tonoit.com` — the **production
   backend** — in all 7 server-side call sites
   (`api/checkout`, `api/portal`, `api/me`, `api/analyze`, `auth/callback`,
   `account/page`, `passkey-backend`). That would point preview traffic at
   production Stripe and production customer data.
   **This is refused: "never use production as the build debugger."**
   Prerequisite: Preview-scoped `TONO_BACKEND_URL`, `NEXT_PUBLIC_SUPABASE_URL`,
   `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `TONO_DEPLOYMENT_ENV=staging`, and both
   `TONO_SUPABASE_*_PROJECT_REF` pointing at **non-production** infrastructure.

### 7.3 Backend production configuration — **owner/infra**
`apple_configured=false`, `google_play_configured=false`, `canonical_sha="unknown"`
on the live service. Prerequisite: set `TONO_APPLE_ROOT_CA_PEM`,
`TONO_APPLE_APP_APPLE_ID`, `TONO_APPLE_ISSUER_ID/KEY_ID/PRIVATE_KEY`,
`TONO_GOOGLE_SERVICE_ACCOUNT_JSON`, `TONO_GOOGLE_BASE_PLAN_IDS` (**required to
grant**), RTDN auth, and `TONO_CANONICAL_SHA` on Render `srv-d9gg8ngk1i2s738lngd0`.
Verify: `/health` shows all true and the real SHA.

### 7.4 Store artifacts are STALE relative to this candidate — **must rebuild**
| | Candidate | Previously staged | Contains the P0/P1 fixes? |
|---|---|---|---|
| iOS `CFBundleVersion` | **101** | **102** (`release/ios-build102-20260724`, signed archive) | **NO** |
| Android `versionCode` | **13** | **14** (`706e61ca`, Play alpha DRAFT) | **NO** |

Both staged artifacts predate this candidate and therefore still carry the
cross-account cache leak, the broken cancel path, and the web 404s. **They must not
be shipped.** Shipping this candidate requires new archives, and store rules demand a
build number **greater** than what is already uploaded (>102 iOS, >14 Play) — a bump
this session was instructed to leave untouched. **Owner decision at upload time.**

### 7.5 Everything else — blocked pending its prerequisite
Physical iPhone/Android acceptance (keyboard/IME, Space cursor, extensions,
accessibility, auth, session persistence); live sandbox revenue loops (Stripe /
StoreKit / Play: trial, upgrade/renewal, portal/cancel, refund/dispute, entitlement
propagation, restore); backup before each production mutation; codesign / archive /
upload / store processing; Vercel production promotion; Render deploy; post-deploy
acceptance against the real origin.

---

## 8. Rollback

| Scope | Action |
|---|---|
| This session's successor | `git reset --hard 5d3fdd7e385391d004e758be6ca759e4ff819916` |
| Both session commits | `git reset --hard 1464d03d9523c56b25f4ae148031e26b1337f7ed` |
| Local artifacts | `docker rmi tono-backend:<HEAD>`; delete `apps/web/.next`, `build/` |
| Provider state | **none to roll back** — nothing was deployed, pushed, aliased, uploaded, or charged |

---

## 9. Release ledger — what is true, by category

| Stage | State | Evidence |
|---|---|---|
| **Built** | ✅ backend image + web artifact at HEAD | `sha256:80e7b7f2…`, `sha256:22df6fb3…` |
| **Runtime-bound** | ✅ container `/health` = HEAD SHA | §4 |
| **Tested (automated)** | ✅ 586 backend · 330 iOS · 31 web · 5 Android · 63 hostile | §3 |
| **Previewed** | ❌ **blocked** — ancestor-of-main + no Preview env | §7.2 |
| **Independently verified** | ⏳ handoff issued, not yet executed | §5 |
| **Deployed** | ❌ not deployed anywhere | §8 |
| **Platform-accepted** | ❌ nothing uploaded; staged artifacts stale | §7.4 |
| **Recipient-visible** | ❌ production still serves `4605b31f` | §4 |
| **Device-verified** | ❌ no physical device run | §7.5 |

**Artifact freshness note:** the sealed backend image and web artifact were built
at commit `a219f98a`. The build-90 closure successor changes only a readiness JSON
and documentation — no runtime code, dependency, or build input — so the artifact
*contents* are unaffected, but the `TONO_CANONICAL_SHA` provenance label is not.
Rebuild both at the final HEAD before any deploy so provenance binds exactly.

**Next irreducible owner actions, in order:**
1. ✅ ~~build-90 gate~~ — **closed 2026-07-25** by owner attestation (§6), with both
   gate scripts executed and passing. Owed only: independent QA reproduction.
2. Create a **Preview-scoped Vercel environment** pointing at non-production
   infrastructure (§7.2).
3. Set the **Render backend env** so Apple/Play verification works and
   `canonical_sha` binds (§7.3).
4. Decide the **build-number bump** for fresh store artifacts (§7.4).

Not self-approved. No release performed.
