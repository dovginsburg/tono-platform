# Tono — Build 126 Finish-Line Seal / Verification Handoff (Opus 4.8)

**Lane:** fresh Opus 4.8 seal/verification lane, sole Tono writer, no subagents,
no background tasks — every verification command was run **synchronously in the
foreground** and awaited to its final exit. **Date:** 2026-08-03.
**Worktree:** `/Users/Ezra/.hermes/claude-worktrees/tono-build126-auth-integration-opus48-20260803`.

This handoff separates verified local evidence from operator-owned gates and
**invents nothing**. Every count below comes from a command whose log path is
recorded; provider / deploy / device / upload states remain **NO** and are the
operator's to earn.

---

## 1. Identity

| Ref | SHA | Tree |
|---|---|---|
| **Validated baseline** | `391b51d0594b0ef30f3ca8e60ea7a2a34f1ef6b4` | — |
| **Candidate base (all iOS/backend/web gates ran here)** | `198a5616803e1a2b048028aadbee23474a302080` | `f1c6078759d1bde53d1bb1200e5ba0f0be8318b4` |
| candidate base parent | `cc6845e596b5bdf3302e54ec0a0112f379d80844` | — |
| **Seal fix commit** (this lane) | `4cd50f4a3abff12ad7ee1aab3acd32f1597f83bb` | `714d0cc3548332eec70e8398715a731f62d7d3c1` |
| seal fix parent | `198a5616803e1a2b048028aadbee23474a302080` | — |
| **Sealed branch tip** | this handoff commit (child of `4cd50f4`) — its SHA is verified by `git ls-remote` after push (§8); a commit cannot embed its own hash. |
| Branch | `claude/tono-build126-auth-integration-opus48-20260803` (no remote ref before this seal) |

**Changed scope vs `391b` baseline:** `46 files changed, 5828 insertions(+), 64
deletions(-)` — the coordinated Build 126 candidate (RevenueCat canary across
backend/iOS/Android/web + the auth-providers repair: iOS Apple entitlement /
Google SPM / passkeys-gated / honest email resend; web implicit-flow email
links; backend email-verification authority). **This lane added exactly one
file** on top: the Android convergence-assertion fix (§6), `+6 −5`, test-only.

**Environment:** macOS 15.5 (Darwin 25.5.0); Xcode 26.5 (17F42), iOS 26.5
SDK/sim; JDK 17 (Zulu 17.0.19) for Android per CI, JDK 21 also present; system
Python 3.9.6 + pytest 8.4.2; Node v22.23.2 / npm 10.9.8. Disk free ≥ 35 GiB
throughout (start 42 GiB; requirement ≥ 20 GiB met).

**Native build lock (`/tmp/amazed-native-build.lock`):** at start it was a
directory whose `owner` recorded a **dead** `pid=3347` (a prior resumed
session's iOS run that was killed as a background task); no `xcodebuild`/Gradle
owner was live, so I reclaimed it and ran all native builds under it. After my
native phase completed it was recreated by another owner (a sibling worktree) —
no conflict, since my native work was finished and this branch is unique.

---

## 2. Build-number surfaces — all four == 126  ✅

`apps/ios/Scripts/bump-build.sh` (the single reviewed authority) exits **0**:
`build-number: all shipped bundles are build 126`. Independent `PlistBuddy`
`CFBundleVersion` read:

| Surface | CFBundleVersion |
|---|---|
| `App/Info.plist` | 126 |
| `KeyboardExtension/Info.plist` | 126 |
| `ShareExtension/Info.plist` | 126 |
| `TonoMessagesExtension/Info.plist` | 126 |

(`project.pbxproj` carries no `CURRENT_PROJECT_VERSION`; the four Info.plists are
the authority.)

---

## 3. Backend suite — 1072 passed / 1 skipped  ✅

`cd apps/backend && python3 -m pytest -q -p no:cacheprovider`
→ **`1072 passed, 1 skipped, 3 warnings in 103.61s`**, exit **0**.
Log: `/tmp/tono-build126-seal/backend.log`. (40 test files; the 1 skip and 3
warnings are pre-existing env warnings — LibreSSL urllib3, Python-3.9-EOL
google-auth — not failures.)

New Build-126 backend tests, confirmed included and green (run again in
isolation for an exact count): `test_email_verification_authority.py` +
`test_revenuecat_canary.py` + `test_revenuecat_client_contract.py`
→ **`66 passed`**. This exercises the email-authority fallback and the
RevenueCat canary (provider→entitlement mapping, `TONO_REVENUECAT_MODE`
off/shadow/authoritative kill switch, backend-stays-authority).

---

## 4. Web gates — tests / type / build green  ✅

From `apps/web` (deps installed with a clean `npm ci` from the committed
`package-lock.json`: **`added 119 packages in 5s`**, exit 0 — the repo's own
pinned lockfile, a local build only, nothing published):

| Gate | Command | Result |
|---|---|---|
| Tests | `npm test` (`node --test` on `src/lib/*.test.ts` + `tests/*.test.cjs`) | **172 pass / 0 fail / 0 skip**, exit 0 |
| Type | `npx tsc --noEmit -p tsconfig.json` | exit **0** (clean) |
| Build | `npm run build` (provenance prebuild + `next build`) | **`✓ Compiled successfully in 11.6s`**, exit 0 |

The new Build-126 route `/api/auth/email/complete` compiles into the route
table. Logs: `web-test.log`, `web-typecheck.log`, `web-build.log`,
`web-npmci.log` under `/tmp/tono-build126-seal/`.

**Lint:** the project has **no ESLint dependency or config** (verified: `eslint`
absent from `package.json`, not installed, no `.eslintrc*`/`eslint.config.*`) —
so `next lint` only tries to *interactively scaffold* one and aborts under a
non-TTY. This is a deliberate baseline design, not a code failure; the project's
static-analysis gate is `tsc --noEmit` (green above) plus the `node --test`
contract suite. Node/next artifacts (`node_modules/`, `.next/`,
`build-provenance.json`) are gitignored — worktree stayed clean.

---

## 5. Android gates — test / lint / assemble green (after the one fix)  ✅

CI-canonical gate (`.github/workflows/ci.yml`): `python3
scripts/ci/prepare_provenance.py` then, from `apps/android` under **JDK 17**
(AGP 8.2.2), `./gradlew testDebugUnitTest lintDebug assembleDebug --stacktrace`.

- **First run FAILED** (exit 1, 4m2s): `:app:testDebugUnitTest` — 1 failing test
  (`PlayBillingManagerGateTest.android120PreservesItsCodeWhileIosAdvancesToReviewedBuild122`:
  `ComparisonFailure … reviewed Build 122 authority expected:<122> but was:<126>`).
  Diagnosed as a **true candidate regression** and fixed minimally (§6).
  Log: `/tmp/tono-build126-seal/android-gate.log`.
- **Re-run after the fix: `BUILD SUCCESSFUL in 1m 10s`, exit 0.**
  Log: `/tmp/tono-build126-seal/android-gate-2.log`.

| Task | Result |
|---|---|
| `testDebugUnitTest` | **112 tests, 0 failures, 0 errors** (app 66 · shared 46 · ime 0) |
| `lintDebug` | **0 errors, 20 warnings** (passed) |
| `assembleDebug` | `app-debug.apk` **19.7 MB** — embeds canonical HEAD provenance |

Artifacts: `apps/android/app/build/outputs/apk/debug/app-debug.apk`;
lint report `apps/android/app/build/reports/lint-results-debug.html`.
(Test total grew from the baseline's ~104 by the candidate's new
`RevenueCatManagerGateTest`.)

---

## 6. The one candidate regression — fixed minimally (exact baseline comparison)

**Defect.** `apps/android/.../PlayBillingManagerGateTest.kt` reads the iOS
`bump-build.sh` `EXPECTED_BUILD` (the single reviewed release authority) and
asserted it equals a hardcoded `"122"`. This file is **not** in the candidate's
46-file scope — it is byte-identical to `391b`.

**Exact baseline comparison (proof it is candidate-introduced, not pre-existing):**

| | `391b` baseline | candidate `198a561` |
|---|---|---|
| iOS `EXPECTED_BUILD` | `"122"` | `"126"` (bumped by candidate `cc6845e`) |
| Android test asserts | `"122"` | `"122"` (unchanged) |
| Test result | **pass** (122==122) | **fail** (expected 122, was 126) |

The iOS side reconciled its own convergence assertions for Build 126, and the
iOS `BuildNumberGuardTests` read `EXPECTED_BUILD` *dynamically* (no hardcoded
number) — so only this Android assertion, which hardcodes the number, was
missed. **Fix (`4cd50f4`, test-only `+6 −5`):** reconcile the assertion value,
its method name, comment rationale, and message to `126`. Android `versionCode`
stays `120`; iOS advances to the reviewed identifier. Re-verified green in §5.

---

## 7. iOS — build-for-testing + FULL signed suite: 938 passed / 0 failures  ✅

Sim `Tono-B126` (iPhone 17, iOS 26.5, booted; UDID
`B0409765-AD2D-40A1-8C0E-FF13F7D58022`). Signed per the baseline
(`DEVELOPMENT_TEAM=4938S9TTBM`; the suite **must** run signed — an unsigned build
strips the app-group entitlement and spuriously fails ~25 keychain/connectivity
tests, so unsigned is *not* the baseline's test mode).

1. **build-for-testing (signed):**
   `xcodebuild build-for-testing -project Tono.xcodeproj -scheme Tono
   -destination 'platform=iOS Simulator,id=B0409765-…' -only-testing:TonoTests
   -derivedDataPath build/ios DEVELOPMENT_TEAM=4938S9TTBM`
   → **`** TEST BUILD SUCCEEDED **`**, exit 0 (~3 min).
   Log: `/tmp/tono-build126-seal/ios-build-for-testing.log`.
2. **test-without-building (signed, full `TonoTests`):**
   `xcodebuild test-without-building … -resultBundlePath build/ios-results.xcresult …`
   → **`Executed 938 tests, with 0 failures (0 unexpected)` in 482.4s**;
   `Test Suite 'All tests' passed`; **`** TEST EXECUTE SUCCEEDED **`**, exit 0.
   **Result bundle:** `apps/ios/build/ios-results.xcresult`.
   Log: `/tmp/tono-build126-seal/ios-test.log`.
   New `Build124AuthProvidersTests` = **16/16 pass**.
3. **CI unsigned compile gate:** `xcodebuild build … 'generic/platform=iOS
   Simulator' CODE_SIGNING_ALLOWED=NO TONO_CANONICAL_SHA=<HEAD> …`
   → **`** BUILD SUCCEEDED **`**, exit 0; `plutil` confirms
   `TonoCanonicalSHA == 198a561…`. Log: `ios-unsigned-build.log`.

**Exact baseline comparison — the four historically-failing tests (from the
standalone `5202d5d` 945/4 run) all RAN and PASSED on the `391b`-integrated 126
tree**, confirming the reconciliation resolved every one (no candidate regression
on iOS):

- `Build112UISurfaceContractTests.testTheFailureMapperIsPinned…` — passed
- `Build115IPadSurfaceLayoutTests.testNoNewControlFallsBelowTheTouchTargetGuideline` — passed
- `Build116SelectedFirstTests.testNoUserVisibleCopyNamesASpecificDeviceFamily` — passed
- `Build114EmailAccountTests.testTheConfirmedAddressIsWrittenInExactlyOnePlaceAndOnlyOnServerProof` — passed

(The count is 938 here vs the standalone lineage's 945 because integration onto
`391b` retired/adapted convergence assertions — e.g. the obsolete Build114 Google
guard — per the candidate's own reconciliation note.)

---

## 8. Aggregate gate table

| Surface | Gate | Result | Evidence |
|---|---|---|---|
| iOS | build-numbers ×4 | **126** | `bump-build.sh` exit 0 |
| Backend | `pytest -q` | **1072 pass / 1 skip** | `backend.log` |
| Backend | RC canary + email-authority | **66 pass** | (subset) |
| Web | `npm test` | **172 / 0 / 0** | `web-test.log` |
| Web | `tsc --noEmit` | **exit 0** | `web-typecheck.log` |
| Web | `next build` | **compiled OK** | `web-build.log` |
| Android | `testDebugUnitTest` | **112 / 0 / 0** | `android-gate-2.log` |
| Android | `lintDebug` | **0 err / 20 warn** | idem |
| Android | `assembleDebug` | **app-debug.apk 19.7 MB** | apk path |
| iOS | build-for-testing (signed) | **SUCCEEDED** | `ios-build-for-testing.log` |
| iOS | full `TonoTests` (signed) | **938 / 0** | `ios-results.xcresult` |
| iOS | CI unsigned build + SHA embed | **SUCCEEDED / == HEAD** | `ios-unsigned-build.log` |

---

## 9. GO / NO-GO ledger (nothing conflated)

| Level | Status | Basis |
|---|---|---|
| **SOURCE_VERIFIED** (all local gates green on the sealed tree) | **GO** | §2–§7 above; one candidate regression found + fixed + re-verified |
| **RevenueCat** | **DORMANT by design** | Backend canary tests pass; iOS keeps `purchases-ios` SPM **deliberately unlinked** and the kill switch **off**; backend stays the sole entitlement authority. Provider **activation is a separate NO** (needs `appl_` key / Xcode link / `TONO_REVENUECAT_MODE`). |
| **PROVIDER_CONFIGURED** (Apple SIWA on App ID, Google iOS OAuth client, passkey Associated-Domains + AASA, server `APPLE_CLIENT_ID`/`GOOGLE_CLIENT_ID`/webauthn env) | **NO** | Portal / DNS / env — operator-owned; source is fail-closed until then (see `apps/ios/AUTH_PROVIDERS_HANDOFF_2026-08-03.md`). |
| **DEPLOYMENT** (Render backend, Vercel web) | **NO — not performed** | This lane does not deploy (constraint). |
| **LIVE_AUTH / PAYMENT_VERIFIED** | **NO** | No deploy; unverifiable without provider config. |
| **SIGNED_DEVICE_VERIFIED** | **NO** | Simulator only; new capabilities are not yet on the App ID; a device/TestFlight archive is neither built nor authorized. |
| **UPLOAD** (App Store Connect / Play) | **NO — not performed & not authorized here** | Build numbers 115/116 (and earlier) are consumed on ASC — confirm a free `CFBundleVersion` before any future archive. |

**Explicitly NOT done (per constraint):** no deploy, no upload, no provider
mutation, no charge, no real-user contact.

---

## 10. Reproduce

```
# build numbers
apps/ios/Scripts/bump-build.sh

# backend
cd apps/backend && python3 -m pytest -q -p no:cacheprovider

# web
cd apps/web && npm ci && npm test && npx tsc --noEmit -p tsconfig.json && npm run build

# android (JDK 17)
python3 scripts/ci/prepare_provenance.py
cd apps/android && JAVA_HOME=$(/usr/libexec/java_home -v 17) \
  ./gradlew testDebugUnitTest lintDebug assembleDebug --stacktrace

# ios (signed suite, booted iOS 26.5 sim)
cd apps/ios
xcodebuild build-for-testing -project Tono.xcodeproj -scheme Tono \
  -destination 'platform=iOS Simulator,id=<booted-udid>' -only-testing:TonoTests \
  -derivedDataPath build/ios DEVELOPMENT_TEAM=4938S9TTBM
xcodebuild test-without-building -project Tono.xcodeproj -scheme Tono \
  -destination 'platform=iOS Simulator,id=<booted-udid>' -only-testing:TonoTests \
  -derivedDataPath build/ios -resultBundlePath build/ios-results.xcresult \
  DEVELOPMENT_TEAM=4938S9TTBM
```

**Bottom line:** the Build 126 candidate is **source-complete and fully green on
every local gate** after one minimal, test-only cross-surface fix. It is
**SOURCE_VERIFIED GO** and remains **provider-/deploy-/device-/upload-gated (all
NO)** — those are the operator's to earn, and none were faked here.
