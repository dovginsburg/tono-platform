# Verification evidence — 2026-07-13

Commands were run from `/Users/Ezra/Projects/apps/tono-platform` unless a working directory is named.

## Passed gates

- `python3 scripts/ci/verify_source.py` — passed for 279 tracked entries; all five imported commits/roots resolved, with no gitlinks, nested Git roots, forbidden generated paths, database files, signing files, or credential filenames tracked.
- `gitleaks git --redact --verbose` — passed across all 88 reachable commits, approximately 125.21 MB, with no leaks.
- `git archive HEAD` followed by `gitleaks dir --redact --verbose` — passed across the 1.62 MB tracked-source archive. Build caches were intentionally excluded; a scan of local `.next` output correctly identified ephemeral Next.js build encryption/signing keys that are ignored and unreachable from Git.
- `git fsck --full --no-dangling` — passed.
- `.venv/bin/python -m pytest -q apps/backend/tests` — `105 passed in 5.83s`.
- `.venv/bin/python scripts/ci/export_openapi.py --check` — `OpenAPI contract matches checked source`.
- `npm ci && npm run build` in `apps/web` with non-secret CI placeholders — Next.js production build passed; 22 static/dynamic routes were emitted. npm reported two donor dependency advisories (one moderate, one critical) and Next.js emitted its existing Edge Runtime warning.
- `./gradlew testDebugUnitTest assembleDebug --stacktrace` in `apps/android` — `BUILD SUCCESSFUL in 1m 4s`, 103 tasks executed. Existing Android Gradle plugin/compileSdk and Kotlin deprecation warnings remain non-fatal.
- `xcodebuild build ... CODE_SIGNING_ALLOWED=NO` in `apps/ios` using the checked protected build-85 Xcode project — passed. `plutil` read the embedded canonical SHA and `legacy-sqlite-unversioned` schema revision from the built app. Existing iOS deprecation/app-icon warnings remain non-fatal.
- Android APK `assets/build-provenance.json` and web `public/build-provenance.json` both contained the generated canonical SHA and schema revision.
- A FastAPI `/health` request returned the generated canonical SHA and `legacy-sqlite-unversioned` schema revision.
- Python YAML parse of `.github/workflows/ci.yml` — passed.
- Original protected iOS object verification: `/Users/Ezra/Projects/apps/tono/ios` still resolves `dc7ea04bec4af57cc901b99ddc034574d6353c10` exactly.

## Integration failures found and resolved

The first backend run exposed seven failures in imported-but-uncommitted account billing/rate-limit work plus a missing `python-multipart` dependency. Account-aware Stripe routing, account webhook updates, the `/v1/analyze` IP cap, and the dependency were completed; the full 105-test suite then passed.

The first generated iOS project accidentally included standalone `verify_build*.swift` scripts and then exposed a deployment-target mismatch. The canonical workflow was corrected to build the protected checked-in build-85 project directly; that build passed and preserved the release project/source authority.

## Environment limitation

A local backend container build was attempted but no `docker`, `podman`, `nerdctl`, `colima`, or `finch` executable exists on this host. Backend Python import/tests passed locally, and canonical CI contains the Docker image build with immutable SHA/schema build arguments and labels. Independent QA should confirm that CI container step on an Ubuntu runner.

## Safety

No production deployment, provider mutation, source-repository reset/clean/commit, or remote push was performed. Donor working trees remain in their pre-existing dirty states; they were read and locally cloned only.
