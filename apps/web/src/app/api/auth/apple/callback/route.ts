// Direct Tono "Sign in with Apple" — CALLBACK.
//
// Apple returns here as a cross-site top-level POST (response_mode=form_post)
// carrying `code` + `state`. This handler:
//   1. validates `state` against the HttpOnly cookie set at start (CSRF),
//   2. exchanges the one-time `code` server-side with Apple, authenticating
//      with a freshly minted short-lived ES256 client-secret JWT,
//   3. fully verifies the returned identity token against Apple's JWKS
//      (signature, issuer, audience = Tono Services ID, expiry, nonce),
//   4. forwards the verified identity token to the canonical backend
//      (`POST /v1/auth/apple/web`), which INDEPENDENTLY re-verifies it and maps
//      the stable Apple `sub` onto the ONE canonical Tono account — the same
//      `apple_sub` the native iOS app converges on — returning a Tono bearer,
//   5. stores that bearer in the site's httpOnly session cookie and lands the
//      person where they were headed.
//
// Every failure is classified by SHAPE into a reviewed login code — never a
// provider message (which would leak implementation detail and differ for a
// known vs unknown address). The transaction cookies are cleared on every exit.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import {
  readAppleWebConfig,
  mintClientSecret,
  exchangeAppleCode,
  verifyAppleIdToken,
  AppleAuthError,
  STATE_COOKIE,
  NONCE_COOKIE,
  NEXT_COOKIE,
  TRANSACTION_COOKIES,
} from '@/lib/apple-web-auth';
import { buildLoginRedirect, buildAppRedirect, sanitizeNextPath, APP_ENTRY_PATH } from '@/lib/auth-redirects';

export const dynamic = 'force-dynamic';

const WEB_APP_VERSION = 'web-114';

function backendUrl(): string {
  return process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
}

/** Attach the session cookies + clear the transaction cookies, then return. */
function finish(res: NextResponse): NextResponse {
  for (const name of TRANSACTION_COOKIES) {
    res.cookies.set(name, '', { path: '/', maxAge: 0 });
  }
  return res;
}

export async function POST(request: Request): Promise<NextResponse> {
  const cookieStore = await cookies();
  const expectedState = cookieStore.get(STATE_COOKIE)?.value;
  const nonce = cookieStore.get(NONCE_COOKIE)?.value;
  const next = sanitizeNextPath(cookieStore.get(NEXT_COOKIE)?.value ?? APP_ENTRY_PATH);

  // Apple sends application/x-www-form-urlencoded on form_post.
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed')));
  }

  // A user who cancels (or any Apple-side error) comes back with `error`.
  if (form.get('error')) {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed')));
  }

  const code = typeof form.get('code') === 'string' ? (form.get('code') as string) : '';
  const state = typeof form.get('state') === 'string' ? (form.get('state') as string) : '';

  // CSRF: the returned state must equal the one bound to this browser. An
  // attacker cannot read the HttpOnly cookie nor forge a matching state, so a
  // cross-site forged POST is refused here regardless of SameSite.
  if (!expectedState || !state || !nonce || state !== expectedState) {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed')));
  }

  const config = readAppleWebConfig(process.env);
  if (!config) {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'unavailable')));
  }
  if (!code) {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed')));
  }

  let identityToken: string;
  try {
    const clientSecret = await mintClientSecret(config);
    identityToken = await exchangeAppleCode({
      code,
      clientId: config.clientId,
      clientSecret,
      redirectUri: config.redirectUri,
    });
    // Full local verification (defense in depth — the backend re-verifies too).
    await verifyAppleIdToken(identityToken, { clientId: config.clientId, nonce });
  } catch (err) {
    // Classified by SHAPE, never by message. An expired/mixed-up token is the
    // same reviewed outcome as any other failed sign-in from the person's view.
    const reason = err instanceof AppleAuthError && err.reason === 'expired' ? 'link_expired' : 'sign_in_failed';
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, reason)));
  }

  // Hand the verified identity token to the canonical backend, which
  // independently re-verifies it (audience = Tono Services ID), registers a
  // per-browser device if this browser has none, and converges the Apple `sub`
  // onto the one canonical account — the SAME account the native iOS Apple
  // sign-in resolves, because both key on `apple_sub`.
  let session: { api_token?: string; plan?: string } | null = null;
  try {
    const res = await fetch(`${backendUrl()}/v1/auth/apple/web`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identity_token: identityToken, nonce, app_version: WEB_APP_VERSION }),
      cache: 'no-store',
    });
    if (res.ok) {
      session = (await res.json()) as { api_token?: string; plan?: string };
    } else {
      // Status only — a response body can echo the bearer or the address.
      const reason =
        res.status === 429 ? 'rate_limited'
        : res.status >= 500 ? 'unavailable'
        : 'sign_in_failed';
      return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, reason)));
    }
  } catch {
    // The message carries the backend host on a TLS/DNS failure; the only
    // diagnosable fact is that sign-in could not complete.
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'unavailable')));
  }

  if (!session?.api_token) {
    return finish(NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed')));
  }

  const res = NextResponse.redirect(buildAppRedirect(next, process.env));
  // Same session cookies every other sign-in path leaves behind, so no
  // downstream surface has to know Apple was involved.
  res.cookies.set('tono_api_token', session.api_token, {
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365, // 1y; rotated on re-auth
  });
  res.cookies.set('tono_plan', session.plan || 'free', {
    httpOnly: false,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
  });
  return finish(res);
}
