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

## Direct Apple web sign-in (Tono-owned OAuth boundary)

Apple sign-in on the website does **not** go through Supabase. The shared
Supabase project's Apple provider is bound to a **sibling product's** Services
ID, so routing Apple through it sent Tono users into another product's consent
screen (and presented that sibling's `client_id` to Apple). Instead the website
owns the Apple OAuth boundary end to end, under **Tono's own Services ID**.

### Flow

1. `/api/auth/apple/start` (server, GET) — fails **closed** unless the full
   server-side boundary is configured. Mints a strong `state` + `nonce`, binds
   them to the browser in short-lived HttpOnly cookies (`SameSite=None; Secure`
   — required because Apple returns via a cross-site `form_post`), and 302s to
   `appleid.apple.com/auth/authorize` with `client_id = tonoit.com`,
   `response_type=code`, `response_mode=form_post`.
2. Apple returns a cross-site POST to `/api/auth/apple/callback` (server).
   It validates `state` against the cookie (CSRF), exchanges the one-time `code`
   at Apple's token endpoint authenticating with a **short-lived ES256
   client-secret JWT minted at runtime** from the private key, and **fully
   verifies** the returned identity token against Apple's JWKS: signature (RS256),
   issuer (`appleid.apple.com`), audience (`tonoit.com`), expiry, and nonce.
3. The verified identity token is forwarded to the backend
   `POST /v1/auth/apple/web`, which **independently re-verifies** it
   (web Services ID audience) and resolves the stable Apple `sub` through the
   SAME `_resolve_provider_signin` primitive the native app uses — provider
   `"apple"`, so web and native Apple identities converge on one `apple_sub`
   account. A fresh browser gets a per-browser device + bearer (like
   `/v1/auth/web`). No silent email merge; 409-on-collision preserved.
4. The callback stores the returned bearer in the same httpOnly `tono_api_token`
   cookie every other sign-in path sets, and clears the transaction cookies.

The crypto (ES256 signing + RS256/JWKS verification) uses the Node runtime's
built-in WebCrypto — no `jose`/`jsonwebtoken` dependency. The core is pure and
injectable (`src/lib/apple-web-auth.ts`), fully unit-tested with an ephemeral
key (`src/lib/apple-web-auth.test.ts`); the backend slice is tested in
`apps/backend/tests/test_apple_web_auth.py`.

### Native ↔ web convergence

Apple issues one stable `sub` per person across a primary App ID
(`com.tonoit.app`) and a Services ID grouped under it (`tonoit.com`), both under
Team `4938S9TTBM`. Because `/v1/auth/apple` (native, audience `com.tonoit.app`)
and `/v1/auth/apple/web` (web, audience `tonoit.com`) both key on `apple_sub`,
the same person's iOS and web Apple sign-ins resolve to one canonical account.
Residual physical-device acceptance (a real iPhone + a real browser proving the
same `sub` end to end against live Apple) is **not** exercised here — it needs
real Apple tokens and is orchestrator/device-owned.

### Configuration

The Apple button renders only when `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID` attests a
Tono-owned Services ID; the start route independently fails closed if any
server secret is missing. Set the button attestation only once the server
secrets below are live.

**Web deployment (Vercel):**

| Env | Value / meaning | Scope |
|---|---|---|
| `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID` | `tonoit.com` — public attestation that the boundary is configured (button visibility gate) | client-inlined |
| `NEXT_PUBLIC_APPLE_WEB_EXPECTED_SERVICES_ID` | optional strict pin, e.g. `tonoit.com` | client-inlined |
| `APPLE_WEB_TEAM_ID` | `4938S9TTBM` — `iss` of the client-secret JWT | **server-only** |
| `APPLE_WEB_KEY_ID` | `5H8DJ2K7DU` — `kid` of the client-secret JWT | **server-only** |
| `APPLE_WEB_CLIENT_ID` | `tonoit.com` — OAuth `client_id` / id-token audience | **server-only** |
| `APPLE_WEB_PRIVATE_KEY` | PKCS#8 **PEM** of the Sign in with Apple key `5H8DJ2K7DU` (**SECRET**; never `NEXT_PUBLIC_`) | **server-only** |
| `APPLE_WEB_REDIRECT_URI` | `https://tonoit.com/api/auth/apple/callback` — must exactly match the return URL registered on the key | **server-only** |
| `TONO_BACKEND_URL` | existing; defaults to `https://api.tonoit.com` | server-only |

**Backend deployment (Render):**

| Env | Value / meaning |
|---|---|
| `APPLE_WEB_CLIENT_ID` | `tonoit.com` — audience `/v1/auth/apple/web` verifies the id-token against. Unset ⇒ endpoint fails closed (503). |

`readAppleWebConfig(process.env)` (web) returns `null` unless team id, key id, a
**Tono-owned** client id, and the private key are all present — so a copy-paste
of the contaminated sibling id can never satisfy the boundary.

### Apple Developer configuration (operator, external)

- **Callback / Return URL** to register on Services ID `tonoit.com`:
  `https://tonoit.com/api/auth/apple/callback`
- **Domain**: `tonoit.com`
- Services ID `tonoit.com` stays grouped to primary App ID `com.tonoit.app`
  (Team `4938S9TTBM`) so the Apple `sub` converges with native.
- The existing return URL that still points at the shared Supabase callback is
  replaced by the URL above.
