# Runbook — direct Tono "Sign in with Apple" (web)

Owner action to bring the Tono-owned Apple web OAuth boundary live. This
replaces the removed path where the website drove Apple sign-in through the
shared Supabase project's Apple provider (which was bound to a **sibling
product's** Services ID, `parentscript.app`). The website now talks to Apple
directly under **Tono's own Services ID**, and converges the Apple identity onto
the same canonical account the native iOS app uses.

Everything in code fails **closed**: until every value below is set, the Apple
button does not render and the flow cannot start. Setting these is the only
thing that turns it on. **No secret values appear in this file.**

---

## 1. The one callback URL to register in Apple Developer

Register this EXACT Return URL on the Tono Services ID (Certificates, IDs &
Profiles → Identifiers → Services IDs → the Tono Services ID → Sign in with
Apple → Configure → Return URLs):

```
https://tonoit.com/api/auth/apple/callback
```

- It must match byte-for-byte the `redirect_uri` the server sends (that is the
  value of `APPLE_WEB_REDIRECT_URI`, which defaults to exactly this URL).
- `tonoit.com` serves the web app under basePath `/app`; the apex path
  `/api/auth/apple/callback` is rewritten to the handler
  (`/app/api/auth/apple/callback`) by `apps/web/vercel.json`, so register the
  **apex** form above, not the `/app/...` form.
- Also ensure the **Website URL / domain** `tonoit.com` is associated with the
  Services ID, and that the Services ID is grouped under the primary App ID
  `com.tonoit.app` (this grouping is what makes Apple issue the **same `sub`**
  for native and web, so the two converge onto one account).

Established Apple facts (non-secret) this boundary expects:

| Fact | Value |
| --- | --- |
| Apple Team ID | `4938S9TTBM` |
| Primary (native) App ID | `com.tonoit.app` |
| Tono Services ID (web `client_id` / id_token audience) | `tonoit.com` |
| Sign in with Apple Key ID | `5H8DJ2K7DU` |

---

## 2. Environment variables

### 2a. Vercel — web app (Production), server-side secrets

Set on the Vercel project for the website. These are **server-only** — do NOT
prefix them with `NEXT_PUBLIC_`; the private key must never enter the browser
bundle. Read only by the two route handlers under
`apps/web/src/app/api/auth/apple/*` via `readAppleWebConfig`.

| Name | Value | Notes |
| --- | --- | --- |
| `APPLE_WEB_TEAM_ID` | `4938S9TTBM` | `iss` of the client-secret JWT |
| `APPLE_WEB_KEY_ID` | `5H8DJ2K7DU` | `kid` header of the client-secret JWT |
| `APPLE_WEB_CLIENT_ID` | `tonoit.com` | Tono Services ID; OAuth `client_id` |
| `APPLE_WEB_PRIVATE_KEY` | *(PEM contents of the .p8 key)* | Paste the FULL PEM including the `-----BEGIN PRIVATE KEY-----` / `-----END PRIVATE KEY-----` lines and its **real newlines**. Do not commit it; it lives only in the Vercel secret store. |
| `APPLE_WEB_REDIRECT_URI` | `https://tonoit.com/api/auth/apple/callback` | Optional — omit to use this exact default. If set, must equal the registered Return URL. |
| `APPLE_WEB_EXPECTED_CLIENT_ID` | `tonoit.com` | Optional hard pin. When set, the config accepts the Services ID **only** if it equals this exactly — belt-and-suspenders against a wrong id. |

> The private key file lives outside the repo in the operator's secret store.
> Install its **contents** into `APPLE_WEB_PRIVATE_KEY`; never read, print, or
> commit the file.

### 2b. Vercel — web app, public render gate

The Apple button renders only when this attestation is present AND Tono-owned.
It is the operator's signal that section 2a is fully configured on this
deployment. (Even if it is set without 2a, the start route still fails closed —
this only controls whether the button is shown.)

| Name | Value | Notes |
| --- | --- | --- |
| `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID` | `tonoit.com` | Public; must be a Tono-owned Services ID or the button stays hidden. The contaminated `parentscript.app` can never satisfy the gate. |
| `NEXT_PUBLIC_APPLE_WEB_EXPECTED_SERVICES_ID` | `tonoit.com` | Optional strict pin for the render gate. |

### 2c. Render — backend (`api.tonoit.com`)

The backend **independently re-verifies** the Apple identity token forwarded by
the web callback, against the web Services ID audience. Set:

| Name | Value | Notes |
| --- | --- | --- |
| `APPLE_WEB_CLIENT_ID` | `tonoit.com` | Audience for `POST /v1/auth/apple/web`. If unset, that endpoint fails closed with 503 (the whole web-Apple flow stays off). Distinct from `APPLE_CLIENT_ID` (= `com.tonoit.app`), the native audience, which is unchanged. |

---

## 3. Rollout order

1. **Apple Developer**: register the Return URL from §1 on the Tono Services ID.
   (The dedicated Sign in with Apple key, id `5H8DJ2K7DU`, already exists.)
2. **Render**: set `APPLE_WEB_CLIENT_ID=tonoit.com`, deploy the backend (the new
   `/v1/auth/apple/web` endpoint ships in this change). Confirm it is live.
3. **Vercel**: set the §2a secrets and the §2b public attestation, then deploy.
4. Verify on a real device: the login page shows "continue with apple";
   completing it lands on `/app/app` with a Tono session, and a native
   iOS Apple sign-in for the same person resolves the **same** `account_id`.

Turn it back off at any time by clearing `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID`
(hides the button) and/or the §2a secrets (start route fails closed).

---

## 4. StoreKit / iOS purchases stay OFF

This boundary is **web sign-in only**. It does not enable iOS StoreKit
purchases. The backend's `apple_configured` flag is gated on a **different**
variable (`TONO_APPLE_ROOT_CA_PEM`, App Store receipt validation) and is
untouched here — keep it unset so new StoreKit purchases remain disabled until
that is separately and deliberately turned on. Do not set
`TONO_APPLE_ROOT_CA_PEM` as part of this rollout. Android Build 120 is
unaffected — nothing here touches Android.

---

## 5. Residual physical-device acceptance (not yet earned)

The full success path (Apple's real authorize → code exchange with the live
key → real id_token) cannot run in CI: this sandbox has no network to
`appleid.apple.com`, and the flow needs the real private key and a real Apple
account. The crypto is exercised end to end against locally generated keys
(`apps/web/src/lib/apple-web-auth.test.ts`, `apps/backend/tests/test_apple_web_auth.py`),
but the following remain to be confirmed once §3 is deployed:

- a real end-to-end web Apple sign-in completing on a physical browser;
- confirming Apple's live id_token carries `aud = tonoit.com` and the nonce
  echoes verbatim (the code assumes the web-flow verbatim nonce, not the native
  SHA-256);
- confirming a person's native iOS Apple identity and web Apple identity land on
  one `account_id` on live data.
