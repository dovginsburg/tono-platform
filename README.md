# tono-platform

Canonical source monorepo for Tono.

## Applications

- `apps/backend` — active FastAPI backend, preserved from the active backend source plus its reviewed working snapshot.
- `apps/web` — active Next.js web application.
- `apps/ios` — protected build-85 iOS application source. The duplicate embedded backend was intentionally excluded.
- `apps/android` — active Android application/IME source with generated output and signing material removed.

Reviewed Postgres, Redis, Alembic, and donor-CI source from `tono-claude` is preserved under `vendor/reviewed/tono-claude`. It is reference input, not active runtime code; activation is deferred to the separately gated schema/storage migration.

## Reproducible local checks

```sh
python3 scripts/ci/verify_source.py
python3 scripts/ci/prepare_provenance.py
python3 -m venv .venv && .venv/bin/pip install -r apps/backend/requirements.txt
.venv/bin/python -m pytest -q apps/backend/tests
(cd apps/web && npm ci && npm run build)
(cd apps/android && ./gradlew testDebugUnitTest assembleDebug)
(cd apps/ios && xcodebuild build -project Tono.xcodeproj -scheme Tono -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO TONO_CANONICAL_SHA="$(git rev-parse HEAD)" TONO_SCHEMA_REVISION="$(cat ../../schema/revision.txt)")
```

No production secret or production deployment is required by these commands. CI runs source hygiene, full-history secret scanning, API contract drift checks, backend tests/image build, web build, Android tests/build, and iOS simulator build.

Provenance and donor decisions are documented in `docs/provenance/`. Canonical remote ownership, exact-SHA staging deploys, rollback handles, and the ban on developer-checkout/dashboard deploys are documented in `docs/provenance/canonical-release.md`.
