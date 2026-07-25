# Tono — Final Mass-Release Candidate Audit (Opus 5)

> **SCOPE NOTICE — added 2026-07-25. This document is NOT evidence for iOS Build 104 or Build 105.**
>
> It audits commit `1464d03d9523c56b25f4ae148031e26b1337f7ed`, where the shipping
> iOS build number was **101** (see §4). Its space-cursor findings describe the
> *earlier* engine — the one carrying **20 XCTest cases and a 67-check verifier**
> — and it cites engine blob `79870a19da77`, which is the **pre-Build-104
> baseline** blob, not the Build-104 engine (`7888ff231b9e`).
>
> Reproduce:
> ```
> git rev-parse e21410b:apps/ios/KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift
> #   -> 79870a19da77bbe107c9d665e752dade88ec2733   (baseline — cited at §2 below)
> git rev-parse af6c3f3:apps/ios/KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift
> #   -> 7888ff231b9e61aed31024407d781b270284bb2a   (Build 104 candidate)
> ```
>
> Build 104 (`af6c3f3`) was independently reviewed and **rejected**: the space
> cursor was inert on device because `SpaceCursorSession` held its text proxy
> `weak` while the controller passed the adapter as a temporary. Nothing in this
> document covers that defect or its remediation. Current space-cursor evidence
> lives in `apps/ios/Tests/SpaceCursorGestureTests.swift`,
> `apps/ios/Scripts/verify_space_cursor_focused.swift` and
> `apps/ios/Scripts/verify_space_cursor_lifetime.sh`.
>
> The audit below is accurate **for the commit it names**. It is preserved
> unedited; only this notice was added.

**Auditor/builder:** one Claude Opus 5 session (`claude-opus-5`, 315/315 assistant turns — see §11)
**Date:** 2026-07-24
**Baseline:** `1464d03d9523c56b25f4ae148031e26b1337f7ed` (tree `ac2a20dc…`, sole parent `1d3a36fd…`) — proven clean before any edit
**Deliberate integration:** sealed iOS Space-cursor commit `08dc4ba8f80e841d924ada7c0dfb41bbf78c8ba2` (five-file diff, applied blob-exact)

---

## 1. Executive verdict

**SOURCE: GO.** **PRODUCTION / APP STORE / PLAY: NO-GO — blocked on human and provider gates that this session must not and did not clear (§9).**

This candidate is one linear successor to the clean web candidate. It closes a **P0 cross-account private-data leak**, two **P1 revenue/consumer-protection defects** (one of which made *cancelling* unreachable on the web, the other unreachable on iOS), consolidates a duplicated rate limiter that grew memory without bound, integrates the sealed Space-cursor change with proven shipping-target membership, and turns the iOS XCTest suite **green for the first time** — it was red at the baseline on a false-negative assertion.

What changed materially:

| | Baseline | This candidate |
|---|---|---|
| Backend tests | 499 passed, 1 skipped | **586 passed, 1 skipped** |
| iOS XCTest (`-scheme Tono`) | **330 run, 1 FAILED** | **330 passed, 0 failures** |
| Web unit tests | 17 passed | **26 passed** |
| Android unit tests | 5 passed | 5 passed |
| Space-cursor engine | absent | 20 XCTest + 67-check verifier, in `TonoKeyboard` |
| Cross-account cache leak | **present** | closed + 16 regression tests |
| Web `/api/portal`, `/api/passkey/*` | **404 in production** | reachable + guarded |

No prices, version numbers, or build numbers were touched. No provider, account, or schema state was mutated. No deploy, upload, submit, or push was performed.

---

## 2. Baseline and integration proof

```
HEAD   = 1464d03d9523c56b25f4ae148031e26b1337f7ed
TREE   = ac2a20dce4391efc7cd8ca0229522074651af7e7
PARENT = 1d3a36fd9f1880d004ffcf106ad547b486540b33
git status --porcelain -> (empty)
```

`1464d03d` is a **divergent sibling** of `origin/main` (`4605b31`), not an ancestor: it carries the canonical-origin `auth-redirects` fix that main lacks. The worktree was reset onto it before the first edit.

**Space-cursor integration was not a blind cherry-pick.** All five files the sealed commit touches were proven byte-identical between its parent `a80c43c` and this baseline — including `KeyboardViewController.swift` (blob `8adfee13…`) and `project.pbxproj` (blob `b079b02c…`) — so there is no textual drift and no stale assumption about helpers the new code calls (`advanceHostSession`, `invalidateCoachWork`, `spellingService`, `documentMutationGeneration`, …all unchanged). After applying, every resulting blob hashes exactly to the sealed commit's:

```
79870a19da77  SpaceCursorEngine.swift
75a8200ec2d2  KeyboardViewController.swift
3b47bd29e26c  verify_space_cursor_focused.swift
8eb0ff2a2e4e  SpaceCursorGestureTests.swift
75bb487e3572  project.pbxproj
```

**Shipping target membership — verified in the build, not on disk.** `SpaceCursorEngine.o` is compiled for both arches under `TonoKeyboard.build` and appears in `TonoKeyboard.LinkFileList` (45 objects), alongside the known-shipping control `BackspaceRepeatEngine.o`. The `.o` carries 169 SpaceCursor symbols including the engine's exact `(pressedAt:movedBeyondSlop:availableLeft:availableRight:)` metadata. A first probe with `nm` on the linked `.appex` found nothing — that was a **probe artifact**: the product binary is symbol-reduced and the known-shipping control is equally invisible there. Object + link-list evidence is therefore the authoritative membership proof.

Target matrix (parsed from `project.pbxproj`): engine in `TonoKeyboard` ✅ and `TonoTests` ✅; correctly absent from `Tono`, `TonoShare`, `TonoMessagesExtension`.

---

## 3. Architecture map

```
                      packages/contracts/commercial-catalog.v1.json
                      (ONE canonical entitlement 'pro'; trial.days = 14; no free tier)
                                        │ single source of truth
        ┌───────────────────────────────┼───────────────────────────────┐
        │                               │                               │
   apps/backend (FastAPI)          apps/web (Next 15, basePath /app)   apps/ios · apps/android
        │                               │                               │
  server.py  ── shared gate ──►  _require_rewrite_entitlement(user)      │
   ├ auth.py      opaque bearer, device→account                          │
   ├ store.py     Account/User; _plan_grants_pro = ONE entitlement fn    │
   ├ payments.py  Stripe: checkout · portal · webhook (signed, inbox)    │
   ├ app_store.py Apple SignedDataVerifier → entitlement_grants          │
   ├ google_play.py Play Developer API + RTDN OIDC                       │
   ├ passkeys.py  WebAuthn      ├ supabase_auth.py  web identity         │
   └ analyze.py   provider prompts + strict variant envelope             │
                                                                          
  Entitlement principal = account UUID (contract §1). Every rewrite route
  calls the ONE gate before any provider call; 402 is distinct from 401/429.
```

**Architectural boundaries inventoried**

| Boundary | Seam | State |
|---|---|---|
| Entitlement policy | `store._plan_grants_pro` → `User.is_pro` / `Account.is_pro` | Single, coherent. No disagreeing inline check. |
| Rewrite authorization | `server._require_rewrite_entitlement` | One chokepoint; grep-enforced by an existing test. |
| Commercial identifiers | `packages/contracts/commercial-catalog.v1.json` + `catalog.py` | Fail-closed loader; env-var *names* only, no secrets. |
| Stripe customer identity | `stripe_customer_bindings` (authoritative) → `accounts` (projection) | **Was split across two orders — fixed (F2).** |
| Web route addressing | Next `basePath` + `vercel.json` apex table | **Was a hand-maintained allowlist — fixed (F3).** |
| Per-IP throttling | `rate_limit.check_ip_rate` | **Was two implementations — consolidated (F4).** |
| Provider prompt inputs | `analyze.build_system_prompt` / `build_user_prompt` | Feeds the cache key after F1. |
| Cross-process privacy | `_log_phase` (no ids), `EventRequest(extra="forbid")` | Verified by probes (§7). |

---

## 4. Findings register

Severity: **P0** ship-blocking data/security defect · **P1** revenue, consumer-protection, or advertised-feature break · **P2** cohesion/correctness worth fixing now · **P3** drift/dead code.

### F1 — P0 · Cross-account private-data leak through the global response cache · FIXED

- **Where:** `apps/backend/server.py:161` (`_analysis_cache_key`), used at `server.py:946`; store at `apps/backend/store.py:1614` / DDL `store.py:175`.
- **Root cause:** `response_cache` is a **global** table keyed *only* by the digest (`cache_key TEXT PRIMARY KEY`, no account/device predicate). The digest covered only `(text, axes, preferred_voice, locale)` — but `thread_context`, `recipient_hint`, and `context_hints` all reach the provider prompt (`analyze.py:1025-1030` and `analyze.py:1013-1018`, where `context_hints` are injected into the **system** prompt as "USER PATTERNS (inferred from this person's history)").
- **Impact:** Two accounts sending the same draft text collided. Account B received a rewrite shaped by account A's **private reply thread** (literally the other party's message) and A's inferred personal patterns. 300 s TTL window, no authentication barrier — both parties merely had to be entitled.
- **Reproducer:** A → `POST /api/analyze {text:"hey", thread_context:"LAYOFF-NEWS-FROM-BOB"}`; B (different `account_id`) → `POST /api/analyze {text:"hey", thread_context:"UNRELATED-DINNER-PLAN"}`. Pre-fix, B's response carried A's marker.
- **Fix:** key derived from the canonical `AnalyzeRequest` actually handed to the provider (`model_dump()`), plus wire-level `locale`/`provider` under reserved keys. A field added to that model is now covered automatically instead of silently widening the leak.
- **Tests:** `apps/backend/tests/test_response_cache_isolation.py` (16). **Red-capability proven: 14/16 fail against the pre-fix key, 16/16 pass after.** Includes a structural test that fails if anyone reverts to hand-picking a subset, and one asserting identical input still hits cache (one provider call for two requests) so the fix did not silently disable caching.

### F2 — P1 · Billing portal unreachable for anonymous accounts; cancelling harder than paying · FIXED

- **Where:** `apps/backend/payments.py` — `create_portal_session` vs `create_checkout_session`.
- **Root cause:** two different customer-resolution orders. Checkout used `get_stripe_customer_binding(account_id) or account.stripe_customer_id or user.stripe_customer_id`; the portal used `account.stripe_customer_id if is_identified else user.stripe_customer_id`. **No current code path ever writes `users.stripe_customer_id`** — `update_subscription` writes plan/status/renews_at only, and `attach_stripe_customer` delegates to the account — so the portal's non-identified branch read a permanently-NULL column.
- **Impact:** an **anonymous canonical account** (contract §1 gives every device one; `is_identified` stays false until sign-in) could complete Stripe checkout, hold a live subscription, and then get `400 "No Stripe customer on file. Start checkout first."` from `/v1/portal` — no self-serve way to update a card or **cancel**. Reachable: `apps/ios/Shared/TonoBackend.swift:733,745` calls both endpoints directly.
- **Reproducer (observed):** register → `/v1/checkout` → `/v1/portal` ⇒ `400`. Captured verbatim in the red run.
- **Fix:** one `_resolve_stripe_customer(store, user)` helper, used by both endpoints, ordered binding-table → account column → legacy column, and deliberately **not** gated on `is_identified`.
- **Tests:** `test_portal_customer_resolution.py` (5) — 4 fail pre-fix. Includes a structural guard that both endpoints call the shared helper and neither reads the dead column, plus a test that a device which never checked out still gets the honest 400.

### F3 — P1 · Seven web API routes returned 404 in production · FIXED

- **Where:** client `fetch()` call sites vs `apps/web/vercel.json` apex rewrite table.
- **Root cause:** `basePath: '/app'` means every handler lives at `/app/api/...`. Next rewrites `<Link href>` for basePath but **not** `fetch()`, raw `<form action>`, or `window.location` — those resolve against the document **origin**. Apex `/api/*` resolved only for the four paths hand-listed in `vercel.json`.
- **Impact:** `/api/checkout`, `/api/analyze`, `/api/me` worked (listed) and `/api/auth/signout` worked (its `<form action>` was explicitly `/app/…`-qualified). **`/api/portal` and all six `/api/passkey/*` routes 404'd** ⇒ web "Manage billing" dead (cancel unreachable — compounding F2) and passkey sign-in/registration entirely dead.
- **Fix:** shared `apiPath()` in `auth-redirects.ts`; all 11 client call sites routed through it, removing the dependency on the apex allowlist. Missing apex rewrites (`/api/portal`, `/api/passkey/:path*`, `/api/auth/:path*`) added as deploy-transition cover for browsers still running the previous bundle.
- **Tests:** `apps/web/src/lib/api-path.test.ts` (5) — fails if a bare `/api/...` fetch/form/navigation reappears, if an `apiPath()` target has no handler, or if the apex table drifts incomplete again. **Red-capability proven** for both the bare-fetch and missing-rewrite guards.

### F4 — P2 · Two rate limiters; the live one grew memory without bound · FIXED

- **Where:** `apps/backend/server.py:136-158` vs `apps/backend/rate_limit.py`.
- **Root cause:** `server.py` carried a private sliding-window dict with **no eviction**, while `rate_limit.py` — already live on `/v1/register` — has a 600 s TTL sweep. The bucket key comes from the client-supplied `X-Forwarded-For` (`_get_client_ip`), so a caller rotating that header grew the dict for the life of the process. `test_rate_limit.py`'s own docstring asserted `backend.rate_limit` "no longer exists"; it did, and was live the whole time — the two had simply drifted.
- **Fix:** `_check_ip_rate` now delegates to `rate_limit.check_ip_rate` (scope `"analyze"`). Limit/window unchanged (`IP_RATE_LIMIT_PER_MIN`, default 20, 60 s); `_IP_RATE_LIMIT` still read at call time so existing monkeypatching works. One deliberate, documented semantic delta: the shared limiter records a rejected attempt, so sustained flooding keeps the window extended — already how `/v1/register` behaves. Now-unused `collections`/`threading` imports removed.
- **Tests:** 3 added to `test_rate_limit.py` — structural (no private window dict), eviction (500 spoofed XFF buckets swept to 1), and call-time limit. Stale docstring corrected.
- **Residual (NOT fixed, deliberately):** `_get_client_ip` trusts the **leftmost** `X-Forwarded-For` entry, which is attacker-controlled. The correct value depends on the terminating-proxy topology (Railway/Fly), so changing it blind risks breaking legitimate throttling. **Recommendation:** pin a trusted-proxy hop count or use the platform's real client-IP header, then re-run `test_rate_limit.py`. Ranked P2, owner decision.

### F5 — P2 · iOS suite red at baseline on a false-negative assertion · FIXED (test only)

- **Where:** `apps/ios/Tests/Build97ShippingPathTests.swift:439`.
- **Finding:** `testCustomChipPaletteIsWebsiteBlue38BDF8` grepped `TonoKeyboardVisualStyle.swift` for `case .custom: return UIColor(hexRGB: "38BDF8")`. That code shape is not in the file and — per `git log -S` — never was. The accent literal legitimately lives in the shared `CoachToneChipContract.accentHex`, where `case "custom": return "38BDF8"` **does** resolve to the website blue. **The shipping behaviour was correct; the test was wrong**, and it left all 330 iOS tests red, masking any real regression.
- **Fix:** retargeted at the real authority — asserts Custom resolves to `38BDF8`, that it still matches `.clearer`, that the keyboard *sources* its accent from the shared contract rather than re-declaring a literal, and that no rose accent (`FB7185`/`9F1239`/`E11D48`/`BE123C`) is used. **Strictly stronger; no shipping colour changed.**
- **Confirmed pre-existing:** the identical test fails at the pristine baseline `1464d03d`.
- **Open design question (escalated, NOT decided):** `TonoKeyboardVisualStyle.swift:149` sets the light-mode *label* companion for `.custom` to `#9F1239` (rose-800). The test's doc comment reserves rose for "the recipient-directed red lane", but `.affectionate` also uses a rose-family accent (`F472B6`), so a blanket ban is clearly not intended. Whether the Custom label companion should be rose is a **design call for the owner**, not one this audit made.

### F6 — P2 · Dead `next.config.js` rewrites shadowing CSRF-guarded handlers · FIXED

- **Where:** `apps/web/next.config.js`.
- **Root cause:** returning rewrites as an **array** puts them all in Next's `afterFiles` phase, consulted only after filesystem routes. Confirmed from the built manifest: `beforeFiles (0)`, and `/app/api/checkout` + `/app/api/analyze` sat in `afterFiles` while the route handlers actually served those paths. The handlers additionally enforce the same-origin CSRF guard and the httpOnly-cookie→bearer exchange — so the dead rewrites read as the live definition of a path while silently omitting both protections. Promoting them to `beforeFiles` (an obvious "fix" for a rewrite that appears not to work) would have dropped both.
- **Also removed:** `/sitemap.xml → /sitemap.xml` and `/robots.txt → /robots.txt`, which compiled to self-referential no-ops because basePath applies to source *and* destination. Apex SEO is served by `vercel.json`, verified by test.
- **Kept:** `/api/tono/:path*` and `/api/health` — no handler behind them, genuinely live.
- **Tests:** `apps/web/src/lib/next-rewrites.test.ts` (3). The guard **caught a real overlap during authoring**: `/auth/:path*` (Supabase proxy) spans the app's own `/auth/callback`. The handler correctly wins by phase ordering, so this is recorded in `ACKNOWLEDGED_OVERLAPS` with its reason and mirrored in a `next.config.js` comment — promoting that block to `beforeFiles` would proxy the OAuth callback to Supabase and break sign-in entirely.

### F7 — P2 · `locale` is inert across the whole backend · REPORTED, NOT CHANGED

- **Where:** `apps/backend/analyze.py:1759` is the *only* occurrence of `locale` in the module, and it is never read. `AnalyzeRequest` declares no `locale` field, so `server.py:943` passing `locale=body.locale` is **silently dropped** by pydantic's default `extra="ignore"`.
- **Impact:** `ApiAnalyzeRequest.locale` and `VariantRequest.locale` are advertised in the published `openapi.json`, and `/v1/locales` advertises seven languages — none of which affect the provider prompt. Verified by probe: a request with `locale="fr"` produces a prompt with no French directive. No shipping client sends `locale`, so nothing is broken **today**; it is a latent contract lie that silently returns English the moment one does.
- **Why not fixed:** the two honest options — thread locale into the prompts (changes LLM output, a product change) or delete the parameter and `/v1/locales` (removes a documented public capability) — are both product decisions, and neither is a release blocker. **Recommendation:** make it real by appending a language directive when `locale != "en"` (behaviour then unchanged for every current client), or retire the surface.
- **Note:** the F1 cache key includes wire-level `locale` deliberately, so it stays correct under either decision.

### F8 — P2 · A failed `/v1/auth/web` strands the user with no re-mint path · REPORTED, NOT CHANGED

- **Where:** `apps/web/src/app/auth/callback/route.ts`.
- **Finding:** if `/v1/auth/web` fails, the callback logs and redirects anyway (deliberate — "don't hard-block login on a backend hiccup"), leaving a Supabase session with **no `tono_api_token`**. `exchangeCodeForSession` has consumed the code, so a refresh cannot re-run the callback: the user is signed in but permanently unentitled until they sign out and back in.
- **Why not fixed:** the bounded fix (re-mint from the live Supabase session on `/api/me`) modifies the credential-minting path, which carries more risk than a defect that requires a backend hiccup during callback and has a working user-side recovery. **Recommendation:** implement the re-mint behind a test that stubs a failing `/v1/auth/web`.

### F9 — P3 · Entrypoint drift · FIXED

`server.py`'s `__main__` block ran `uvicorn.run("Backend.server:app")` — capitalised, resolving only on a case-insensitive filesystem, and unreachable anyway because the module uses package-relative imports. The module docstring said `uvicorn server:app`. Both now match the Dockerfile CMD exactly (`backend.server:app`), with the constraint documented.

### F10 — P3 · Stale comment claiming a fake-success form · FIXED

`TonoFooter.tsx` carried a comment stating the newsletter form "is a stub that shows a success state locally" — describing a mock/demo path that had already been replaced by a mailto link directly above it. Removed; the file no longer advertises a no-op endpoint it doesn't have.

### F11 — P3 · Permanently-stale iOS verifier scripts · REPORTED, NOT CHANGED

`Scripts/verify_build83.py` and `verify_build85.py` hard-pin `CFBundleVersion == '83'` / `'85'`; the shipping build is **101**. They can never pass without reverting the build number (forbidden, and wrong). Confirmed failing identically at the pristine baseline. **Recommendation:** delete or re-pin — they currently produce permanent red noise that trains readers to ignore verifier output.

### F12 — P3 · Verifier usage headers drifted from their dependency closure · REPORTED, NOT CHANGED

`verify_live_tone_privacy.swift` and `verify_live_tone_v1_focused.swift` document `swiftc` invocations missing sources their inputs now require (`LiveToneCopy`, `LiveToneOpportunityFamily`, …), so the documented command fails to compile. Both **pass** when given the real closure (299 and 151 checks). Recommendation: update the headers.

### F13 — P3 · Observations recorded, no action taken

- CORS defaults to `*` (`server.py:352`) with `allow_credentials=False`; the comment says to lock it down "once apps/web has a deployed domain", which has happened. Bearer tokens are httpOnly and never JS-attachable from a browser, so this is not currently exploitable — but the stated intent is unmet. Owner decision (needs the real client-origin list).
- `/v1/whoami` is a public debug endpoint echoing caller IP/XFF/User-Agent (JSON, self-only).
- `admin_stats` reaches into `store._conn` / `store._run` — a leaky abstraction in an admin-only path.
- Web `/api/analyze` hardcodes `axes: ['warmer','clearer','funnier','safer']`; the backend overrides them from `CANONICAL_COACH_AXES` regardless, so the list is inert duplication.
- `conftest.py` still sets `FREE_DAILY_LIMIT`; deliberate — `test_entitlement_gate` asserts no value of it can reopen access.

---

## 5. Changes made

20 files modified, 5 test files added: **+1,259 / −83** on tracked files, plus 1,131 lines of new tests.

| Area | Files | What |
|---|---|---|
| Backend fix | `server.py`, `payments.py` | F1 cache key at the canonical seam; F2 shared customer resolution; F4 limiter consolidation; F9 entrypoint |
| Backend tests | 3 new + `test_api.py`, `test_rate_limit.py` | 87 new backend tests |
| iOS | 5 sealed files (blob-exact) + `Build97ShippingPathTests.swift` | Space-cursor integration; F5 test retarget |
| Web | `next.config.js`, `vercel.json`, `auth-redirects.ts`, 6 components | F3 `apiPath()` seam; F6 dead rewrites; F10 comment |
| Web tests | 2 new | 9 new web tests |

Every fix is behaviour-preserving where behaviour was correct, and each carries a regression test. Three fixes were proven **red-capable** by reverting the fix and observing failure (F1 14/16, F2 4/5, F3 both guards).

---

## 6. Test results

| Suite | Command | Result |
|---|---|---|
| Backend | `pytest apps/backend/tests` | **586 passed, 1 skipped** |
| API contract | `scripts/ci/export_openapi.py --check` | **matches checked source** |
| Source hygiene | `scripts/ci/verify_source.py` | **ok — 456 tracked entries, 5 imports verified** |
| Provenance | `unittest scripts/ci/test_prepare_provenance.py` | **5 passed** |
| Web unit | `npm test` (apps/web) | **26 passed** |
| Web typecheck | `npx tsc --noEmit` | **clean** |
| Web build | `npm run build` | **succeeded, 30 static pages, all 11 API routes in manifest** |
| Web prod deps | `npm run audit:prod` | **0 vulnerabilities** |
| iOS build | `xcodebuild build -scheme Tono` (CI parity) | **BUILD SUCCEEDED**, `TonoCanonicalSHA` matches HEAD |
| iOS tests | `xcodebuild test -scheme Tono -only-testing:TonoTests` | **330 passed, 0 failures** |
| iOS Space-cursor | `SpaceCursorGestureTests` | **20 passed** |
| iOS verifiers (Swift) | space-cursor / live-tone privacy / opportunity / shortcut / focused | **67 / 299 / 161 / 50 / 151 checks — all pass** |
| iOS verifiers (Python) | imessage-appintent, messages-extension, check_pbxproj | **pass** |
| Android | `./gradlew testDebugUnitTest assembleDebug` | **BUILD SUCCESSFUL, 5 tests, 0 failures**, APK provenance matches HEAD |

### Suites that could not run — exact missing prerequisite

- **`npm run lint` (web):** not runnable non-interactively. No ESLint config is committed, so `next lint` prompts "How would you like to configure ESLint?" and blocks. **CI does not run lint either.** Not faked as a pass. Prerequisite: commit an ESLint config (or migrate to the ESLint CLI, which `next lint` now recommends) and add it to CI.
- **`build90_recovery_gate.py` / `verify_build91_entitlement_contract.py`:** fail closed by design pending **human-supplied evidence** — see §9. Not a code defect; confirmed identical at baseline.
- **`verify_build83.py` / `verify_build85.py`:** structurally unpassable (F11); pre-existing.

---

## 7. Hostile / property probes

`apps/backend/tests/test_hostile_release_probes.py` — **63 probes, all passing**:

- **Auth boundary (16):** empty/garbage/oversized/NUL/RTL-override/mathematical-alphanumeric/SQLi bearer values ⇒ always 401/403/422, never 2xx, never 5xx. Non-ASCII values are sent as **raw UTF-8 bytes** because a conforming HTTP client cannot put them in a `str` header — the first attempt failed on that and was corrected rather than deleted.
- **Cross-account isolation (2):** another device's token cannot assume your identity; `DELETE /v1/account` revokes only the caller and leaves the other account intact.
- **Entitlement exactness (11):** `active`/`trialing`/`past_due` entitle; `canceled`/`incomplete`/`incomplete_expired`/`unpaid`/`paused`/empty fail closed — **and so do `"ACTIVE"` and `"active "`**, so no case- or whitespace-sloppy match can reopen access. Expired and **malformed** coupon timestamps fail closed (deny on parse error, never grant).
- **Unicode/malformed (13):** NUL, emoji floods, RTL override, combining-mark storms, regional indicators, XSS/SQLi/template/JNDI payloads ⇒ no 5xx. Oversize drafts rejected, not truncated. `/v1/events` **422s** on an undeclared `message_text` field, proving the `extra="forbid"` privacy guard is structural.
- **Webhook (3):** unsigned and forged signatures rejected 400; a replayed event id ACKs `duplicate: true` without reprocessing; a **late redelivery of an older `active` state under a new event id cannot resurrect a canceled subscription**.
- **Logging redaction (2):** draft text, thread context, and the bearer token never appear in logs at DEBUG; `tono.phase` lines carry no device id, token, or payload.
- **URL/redirect (13):** 11 open-redirect attempts (cross-origin, scheme downgrade, protocol-relative, suffix/userinfo confusion, `javascript:`, `data:`) all fall back inside the allowlist; the redirect base ignores an attacker `Host` header and rejects non-HTTPS configuration.

---

## 8. Remaining risks

1. **`X-Forwarded-For` trust (F4 residual)** — leftmost-hop trust means per-IP throttling is side-steppable by header rotation. Deliberately not changed without the deployment topology.
2. **`locale` contract lie (F7)** — harmless today, silently wrong the first time a client requests a non-English rewrite.
3. **Auth-callback strand (F8)** — recoverable only by sign-out/sign-in.
4. **CORS `*` (F13)** — stated intent unmet; not currently exploitable.
5. **Custom chip label hue (F5)** — open design question, escalated undecided.
6. **Single-instance rate limiting** — `rate_limit.py` is in-memory by design; horizontal scaling needs Redis, as its own header notes.
7. **No lint gate (§6)** — style/quality regressions are unguarded in CI.
8. **iOS tests are not in CI** — the `Tono` scheme *does* wire `TonoTests.xctest`, but CI runs only `xcodebuild build`. The suite that this session turned green will not stay green automatically. **Recommendation: add `xcodebuild test` to the iOS CI job.**

---

## 9. Human, physical-device, and provider gates — NOT cleared here

**The repository's own release gate is currently NOT READY, by design:**

```
build90-recovery-gate: NOT READY (fail closed)
  - build-90 charged-before-upgrade prerequisite UNRESOLVED: supply either
    checkout-disabled provider/TestFlight evidence or an owner-approved
    bounded recovery policy (build91_release_readiness.json or
    TONO_BUILD90_RECOVERY_EVIDENCE)
```

This is an **owner decision about real users who may have been charged before upgrading**. It is not a code defect, it cannot be satisfied from source, and this session did not and must not clear it. `verify_build91_entitlement_contract.py` fails for the same reason.

Also required before any release:

- Independent exact-object QA against this commit's tree hash.
- Physical iPhone checks: keyboard **full-access** behaviour, the new **space hold/drag caret** under real touch and VoiceOver, Messages extension, Share extension, App Intent / Shortcut.
- Physical Android checks: IME behaviour, Play billing flow.
- **Live revenue-loop proof** in Stripe/StoreKit/Play sandboxes: 14-day trial start, renewal, cancel, refund, dispute — including the F2 portal path on an anonymous account, and the F3 web passkey + billing routes on the deployed origin.
- Codesign, archive, upload, App Store Connect and Play processing; Vercel promotion; backend deploy.
- Provider-console gates the catalog explicitly does **not** control: App Store Connect intro offer, Stripe Price trial-less configuration, Play Console free-trial offer — all must equal `trial.days = 14`.
- Play payments-profile blocker and the alpha vc14 rollout remain outstanding per project memory.

---

## 10. Release recommendation

**SOURCE GO** — this tree is coherent, all runnable suites are green, the sealed change is integrated with proven shipping-target membership, and one P0 plus two P1 defects are closed with red-capable regression tests.

**PRODUCTION / STORE: NO-GO** until §9 is cleared by a human. I am not approving or releasing this. The single highest-priority external step is resolving the build-90 charged-before-upgrade evidence, because the repository itself refuses to certify the entitlement contract until it exists.

Rollback is a single `git reset --hard 1464d03d9523c56b25f4ae148031e26b1337f7ed`.

---

## 11. Model and authority proof

Verified **before** substantive work:

- `ANTHROPIC_API_KEY` — **absent**; `ANTHROPIC_BASE_URL` — **absent**; `ANTHROPIC_AUTH_TOKEN` — **absent**.
- Auth: claude.ai first-party OAuth, `organizationType = claude_max`, `organizationRateLimitTier = default_claude_max_20x`.
- No `apiKeyHelper`, no `forceLoginMethod`, no model/env override in any settings file (`~/.claude/settings.json` sets only `"model": "opus"`).

Verified **at completion**, from the session transcript (808 records):

```
claude-opus-5 : 315 assistant turns   (100% — no other model observed)
output_tokens : 329,714
cache_read    : 70,619,337
cache_creation: 949,485
```

Nothing here is relabelled or reconstructed; the model string is read directly from the recorded turns.
