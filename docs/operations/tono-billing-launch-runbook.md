# Tono billing launch runbook (build 101 revenue integration)

Status: documentation only. This file contains **no secrets, tokens, price IDs,
or row-level data** — only environment-variable NAMES, commands, and the
sequence to run them. It is the operator checklist for taking the
backend + website billing candidate live without changing approved prices or
making a real charge.

Companion documents (do not duplicate them here):

- `docs/operations/render-persistent-disk-and-blueprint.md` — the Render
  service, the `/data` persistent disk, and the fail-closed DB-path guard.
- `docs/operations/tono-production-sqlite-cutover.md` — the executed snapshot,
  encryption identity, and isolated-restore evidence.
- `packages/contracts/commercial-catalog.v1.json` — the single versioned
  mapping of every store product to the one canonical `pro` entitlement.

---

## 1. Commercial catalog (single source of truth)

All product → entitlement mapping lives in
`packages/contracts/commercial-catalog.v1.json` (version `1.0.0`). The backend
loads and validates it through `apps/backend/catalog.py`; the App Store
product-id default and the Stripe price env-var names are both sourced from it,
and `apps/backend/tests/test_commercial_catalog.py` fails closed if the catalog,
the backend, the iOS StoreKit config, or the Android `BillingContract.kt` ever
drift apart.

| Canonical entitlement | Provider | Product identifier / config | Interval |
| --- | --- | --- | --- |
| `pro` | Stripe (web) | env var `STRIPE_PRICE_PRO_MONTHLY` | month |
| `pro` | Stripe (web) | env var `STRIPE_PRICE_PRO_YEARLY` | year |
| `pro` | App Store (iOS) | `com.tonoit.pro.monthly` | month |
| `pro` | App Store (iOS) | `com.tonoit.pro.yearly` | year |
| `pro` | Google Play (Android) | `com.tonoit.pro.monthly` | month |
| `pro` | Google Play (Android) | `com.tonoit.pro.yearly` | year |

Approved display prices (reference only, not the charge authority): **$3.99/mo,
$39.99/yr**. A store/client purchase never directly grants access — access is the
server's deterministic projection (`apps/backend/store.py` `User.is_pro`).

---

## 2. Required environment variable NAMES (values set in the provider dashboard)

**No values appear here.** Set them in the Render service env (backend) and the
Vercel project env (web). The backend fails closed when the persistence / auth /
webhook settings below are missing (returns 503 or refuses to boot), so an
unset name surfaces loudly rather than silently granting or losing data.

### Backend (Render service `srv-d9gg8ngk1i2s738lngd0`)

Persistence & platform (fail-closed on Render):
- `TONO_DB_PATH` (must resolve under `/data`)
- `RENDER` (injected by Render; the DB-path guard keys off it)
- `PUBLIC_BASE_URL`
- `CORS_ALLOWED_ORIGINS`
- `TONO_CANONICAL_SHA`, `TONO_SCHEMA_REVISION` (provenance labels, surfaced by `/health`)

Stripe (web billing):
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_PRO_MONTHLY`
- `STRIPE_PRICE_PRO_YEARLY`
- `STRIPE_RECONCILE_LIMIT` (optional; reconciliation batch cap)

Apple App Store (iOS entitlement verification):
- `TONO_APPLE_ROOT_CA_PEM` (required — verification is 503 until set)
- `TONO_APPLE_BUNDLE_ID`
- `TONO_APPLE_PRODUCT_IDS` (optional; defaults to the catalog values)
- `TONO_APPLE_ENVIRONMENTS`
- `TONO_APPLE_APP_APPLE_ID` (required for Production verification)
- `TONO_APPLE_ISSUER_ID`, `TONO_APPLE_KEY_ID`, `TONO_APPLE_PRIVATE_KEY`
  (App Store Server API — current-provider reconciliation + Set-App-Account-Token)

Identity / auth:
- `APPLE_CLIENT_ID`, `GOOGLE_CLIENT_ID`
- `SUPABASE_URL`, `SUPABASE_JWKS_URL`, `SUPABASE_ISSUER`, `SUPABASE_AUD`,
  `SUPABASE_JWT_SECRET`
- `WEBAUTHN_RP_ID`, `WEBAUTHN_RP_NAME`, `WEBAUTHN_ORIGIN`
- `TONO_ADMIN_SECRET`

LLM provider + tuning (not billing):
- `TONO_PROVIDER`, `ANTHROPIC_API_KEY`, `TONO_MODEL`, `OPENAI_API_KEY`,
  `OPENAI_MODEL`, `FREE_DAILY_LIMIT`, `DRAFT_MAX_CHARS`, `IP_RATE_LIMIT_PER_MIN`,
  the `TONO_RATE_LIMIT_*` set, `COLLECTIVE_MIN_DEVICES`, `TONO_LOG_LEVEL`.

Slack (optional integration): `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`,
`SLACK_SIGNING_SECRET`, `SLACK_RATE_LIMIT_PER_MIN`.

### Web (Vercel project, deployed at `tonoit.com/app`)

- `TONO_BACKEND_URL`
- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_SITE_URL`
- `TONO_DEPLOYMENT_ENV`, `TONO_SUPABASE_STAGING_PROJECT_REF`,
  `TONO_SUPABASE_PRODUCTION_PROJECT_REF`

The web checkout proxy (`apps/web/src/app/api/checkout/route.ts`) sends Stripe an
explicit, basePath-aware `success_url` (`/app/welcome-pro`) and `cancel_url`
(`/app/pricing`), and the portal proxy (`/api/portal`) sends `return_url`
(`/app/account`). These do not depend on the backend's `PUBLIC_BASE_URL`
default, which omits the `/app` basePath.

---

## 3. Render DB snapshot + encrypted backup + integrity / count / rollback

The executed snapshot and its evidence live in
`docs/operations/tono-production-sqlite-cutover.md` (backup id, AES-256-CBC /
PBKDF2 identity, ciphertext SHA-256, macOS Keychain key location, and the
`PRAGMA integrity_check = ok` + schema-hash + table-count match). Re-run this
sequence before any deploy that could touch `/data`:

1. **Snapshot.** With the container quiesced (or from a read replica of the
   `/data` disk), copy `/data/tono.db`, `/data/tono.db-wal`, `/data/tono.db-shm`
   together (never the `.db` alone — the WAL holds uncheckpointed writes).
2. **Integrity + counts (on an isolated copy, never production).**
   - `PRAGMA integrity_check;` must return `ok`.
   - Record per-table row counts and the schema SHA-256 (as in the cutover doc's
     "Isolated restore evidence" table).
3. **Encrypt online.** AES-256-CBC + PBKDF2 (600k iterations, random salt);
   store only the ciphertext + Keychain-held key. Record the ciphertext
   SHA-256 and byte length. File mode `0600`.
4. **Verify round-trip.** Decrypt into an isolated temp dir, re-open with SQLite
   (this checkpoints the WAL), and confirm the schema SHA-256 and aggregate
   table counts match the pre-encryption values. Truncate the plaintext temp
   files to zero afterwards.
5. **Rollback.** Keep the pre-change encrypted artifact + a second pre-seeded
   volume. To roll back: stop the container, detach the current `/data` volume,
   attach the known-good volume (or restore the decrypted snapshot onto a fresh
   `/data`), restart, and re-run the persistence smoke in §5.

Automated persistence checks:
- `apps/backend/scripts/verify_sqlite_persistence.py` — registers/reuses a
  device, records `used_today`, and re-checks `/v1/me` after a redeploy/restart
  to prove `device_id` / `plan` / `used_today` survived.
- `scripts/ci/docker_cold_volume_smoke.sh` (also driven by
  `apps/backend/tests/test_docker_cold_volume.py` with `TONO_RUN_DOCKER_SMOKE=1`)
  — cold-starts the image on a fresh root-owned volume, proves non-root uvicorn +
  `/data` chown, writes a device row, restarts on the same volume, and asserts
  the row persisted and files stayed `tono`-owned.

---

## 4. Image / provenance checks

- The backend Docker image is labelled at build time with
  `org.opencontainers.image.revision` = `TONO_CANONICAL_SHA` and
  `com.tonoit.schema-revision` = `TONO_SCHEMA_REVISION`
  (`apps/backend/Dockerfile`). The running service echoes both at
  `GET /health` (`canonical_sha`, `schema_revision`).
- **Confirm the deployed SHA matches the reviewed commit.** `/health.canonical_sha`
  must equal the git SHA this candidate was sealed at, and the image label must
  match. A mismatch means an unreviewed image is live — do not promote.
- Source provenance is enforced by `scripts/ci/verify_source.py` (fails on
  gitlinks, nested repos, secrets-by-name, committed `.env`/keystores/`.db`) and
  recorded by `scripts/ci/prepare_provenance.py` into `docs/provenance/`.
- `/health` is redacted: it returns only boolean `stripe_configured` /
  `slack_configured` flags and non-secret metadata — never key values.

---

## 5. Non-charging / test-mode live acceptance

Run these against the live deployment **without creating a real charge**:

1. **Health + provenance.** `GET /health` returns `status: ok`,
   `stripe_configured: true`, and the expected `canonical_sha` / `schema_revision`.
2. **Fail-closed sanity.** With Stripe unset the checkout/webhook routes return
   503 (verified by the suite); confirm the live service instead reports
   `stripe_configured: true`, i.e. the secrets are present.
3. **Stripe test mode (no real money).** Point the service at Stripe **test**
   keys/prices, run a Checkout with a Stripe test card, and confirm:
   pricing → sign in → checkout → `/app/welcome-pro` polls `/api/me` → the
   webhook flips the account to `is_pro` → `/app/account` shows the plan and the
   **manage billing** button opens the Stripe billing portal (cancel works).
   Then switch to live keys for launch; no live charge is made during acceptance.
4. **Apple Sandbox.** Verify a StoreKit **Sandbox** transaction through
   `POST /v1/app-store/subscription` grants `pro`; a refund/revoke
   notification revokes it. (Apple is under App Review — no public App Store
   badge is shown on the site.)
5. **Google Play closed test.** Android is closed-test only and server-side Play
   verification is **not yet implemented** (see §6) — a Play purchase does not
   grant Pro. No public Google Play badge is shown on the site.
6. **Persistence.** Run `verify_sqlite_persistence.py` across a restart, and (if
   Docker is available) `scripts/ci/docker_cold_volume_smoke.sh`.

---

## 6. Remaining independent-QA / deploy / provider gates (not done here)

- **Google Play server verification** — Play Developer API + RTDN ingestion and
  a `provider='google'` projection are not implemented. Until they land, Android
  Pro is intentionally fail-closed. Confirm each product's **base-plan id** in the
  Play Console and record it in the catalog when implementing.
- **Apple App Review** — App Store product approval is pending; only Sandbox is
  exercised. Do not show a public "Download on the App Store" badge until live.
- **Live Stripe cutover** — swapping test → live keys/prices and registering the
  production webhook endpoint is a dashboard action performed by the operator.
- **Production deploy / volume cutover** — see the cutover doc; not executed by
  this candidate.
- **Independent QA** — an out-of-band reviewer should re-run §3–§5 before launch.
