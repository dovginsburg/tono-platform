# Web canonical-account auth & checkout contract

This documents the web sign-in / checkout slice added so a person authenticating
through the website converges onto the **same canonical backend account** as
every other browser/device they use, and so all money binds to that account.

## Flow

1. Browser authenticates with Supabase (Apple/Google/magic-link). Supabase
   issues a signed **access token** (JWT).
2. `apps/web/src/app/auth/callback/route.ts` (server-side) exchanges the code
   for the Supabase session and POSTs the access token to the backend at
   `POST /v1/auth/web`.
3. Backend `POST /v1/auth/web`:
   - Verifies the JWT **cryptographically** against the configured issuer /
     JWKS (RS256/ES256) or shared secret (HS256), plus audience and expiry.
     No decode-only path — unconfigured ⇒ `503`, invalid ⇒ `401`.
   - Extracts the stable provider subject (`sub` = Supabase user id) and the
     email **only when `email_verified`** — an unverified email is never
     persisted and never drives a merge.
   - Reuses the canonical provider-linking primitive
     (`upsert_account_by_provider("supabase", ...)` +
     `_resolve_provider_signin`), so a fresh browser registers a random
     per-browser device and links it to the one account keyed by `sub`.
     Collisions preserve the existing `AccountConflictError` → `409` behavior.
   - Returns a normal backend bearer (`api_token`) + `account_id`.
4. The callback stores the bearer in an **httpOnly, secure, sameSite** cookie
   (`tono_api_token`).
5. `POST /api/checkout` requires that cookie, enforces same-origin (CSRF), and
   forwards it as `Authorization: Bearer …` to `POST /v1/checkout`. The backend
   **refuses anonymous checkout** (`401`), so no Stripe session is ever created
   without account metadata + `client_reference_id`.

## Convergence guarantees

- Same person, second browser → identical `account_id` (both link to the
  account owning their Supabase `sub`).
- Different people never merge (distinct `sub` ⇒ distinct account).

## Account deletion — `DELETE /v1/account`

Authenticated (live bearer for a device linked to the account). Revokes every
session/device (rotates tokens, nulls device credentials), deletes private data
(passkeys), and **tombstones** the account row (`deleted_at` set; `apple_sub` /
`google_sub` / `supabase_sub` / `email` cleared) while preserving append-only
billing/provider audit facts (Stripe customer/subscription ids, entitlement
grants, `stripe_events`). A tombstoned account can never again be resolved by a
provider subject or grant Pro by identity.

## Configuration (backend env)

Set **one** verification path (fails closed otherwise):

- Asymmetric (recommended): `SUPABASE_URL=https://<ref>.supabase.co`
  (derives JWKS `…/auth/v1/.well-known/jwks.json` and issuer `…/auth/v1`), or
  set `SUPABASE_JWKS_URL` + `SUPABASE_ISSUER` explicitly.
- Symmetric (legacy): `SUPABASE_JWT_SECRET` (+ optional `SUPABASE_ISSUER`).
- `SUPABASE_AUD` — audience, defaults to `authenticated`.

Web env: `TONO_BACKEND_URL` (defaults to `https://api.tonoit.com`). The old
`TONO_BACKEND_ADMIN_SECRET` path is removed — the web callback no longer mints
device tokens by admin secret.

`supabase_auth.config_is_valid()` reports whether at least one path is set,
for startup diagnostics.
