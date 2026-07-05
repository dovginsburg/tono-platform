# Tono Backend

One FastAPI app for the whole platform: device-token auth, the rewrite
endpoint, Stripe-account billing, WebAuthn passkeys, Slack OAuth, and
optional rate-limit/usage telemetry.

## Stack

- Python 3.11+ (3.9+ for local dev)
- FastAPI + uvicorn (async)
- Postgres via SQLAlchemy async + asyncpg
- Redis for short-lived state (WebAuthn challenges, rate-limit windows)
- Alembic for migrations
- Stripe (`>=7,<16`), PyJWT (`>=2.8,<3.0`), webauthn (`>=2.0,<3.0`)

## Run locally

```sh
cd apps/backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Bring up Postgres + Redis
docker compose up -d postgres redis

# Apply migrations
alembic upgrade head

# Start the API on :8765 (matches BuildConfig defaults in apps/android
# and NEXT_PUBLIC_TONO_API_URL in apps/web)
uvicorn Backend.server:app --port 8765 --reload
```

OpenAPI docs at `http://localhost:8765/docs` once the server is up.

## Deploy

Three production targets are configured on disk:

- `Dockerfile` (universal — used by all three)
- `railway.toml` (Railway)
- `fly.toml` (Fly.io)

`docker-compose.yml` is the local-only stack (Postgres + Redis + the app
itself).

## Configuration

Copy `.env.example` to `.env` and fill in:

```
DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/tono
REDIS_URL=redis://localhost:6379/0
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
JWT_SIGNING_KEY=...
WEBAUTHN_RP_ID=localhost
WEBAUTHN_RP_NAME="Tono"
SLACK_CLIENT_ID=...
SLACK_CLIENT_SECRET=...
OPENAI_API_KEY=...      # optional; server can hold LLM keys for the
ANTHROPIC_API_KEY=...   # device, or devices call providers directly
```

## Endpoints (selection)

Public:

- `GET  /health`
- `POST /v1/analyze` — provider passthrough, no auth (caller's key)

Authenticated (device bearer token):

- `POST /v1/register`, `GET /v1/me`
- `POST /api/analyze` — server-held provider keys, daily + IP rate limits
- `POST /v1/event/axis` — analytics
- `POST /v1/checkout`, `POST /v1/portal`, `POST /v1/stripe/webhook`
- `GET  /slack/install`, `GET  /slack/oauth`, `POST /slack/command`

WebAuthn passkeys, social auth, and passkey-first device registration are
wired into `Backend/passkeys.py` / `social_auth.py`.

## Tests

```sh
cd apps/backend
pytest -q
```

Tests live under `apps/backend/tests/`.

## Out of scope for `tono-platform`

This subtree was cherry-picked from `dovginsburg/Tono-/apps/backend/`
via `git subtree add` in commit `c2bbfba`. New development continues in
`Tono-` until the final-excellence gate (`t_319676e8`) clears this
subtree. The older `dovginsburg/tono-backend` repo is superseded by this
one and is archive-pending — see `../../OWNERSHIP.md`.
