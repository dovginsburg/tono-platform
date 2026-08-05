// Direct Tono "Sign in with Google" (GIS) — CREDENTIAL exchange.
//
// The browser runs Google Identity Services under Tono's OWN Web client id
// (consent screen "Tono") and receives a signed id token in a JS callback. The
// page POSTs that token here. This server route:
//   1. forwards the id token to the canonical backend (`POST /v1/auth/google/web`),
//      which INDEPENDENTLY verifies it (signature against Google's JWKS, audience
//      = the Tono Web client id, issuer, expiry) and maps the stable Google `sub`
//      onto the ONE canonical Tono account — the same `google_sub` the native app
//      converges on — returning a Tono bearer,
//   2. stores that bearer in the site's httpOnly session cookie (a browser cannot
//      set httpOnly itself, which is exactly why this hop is server-side),
//   3. answers JSON the client uses to navigate into the app.
//
// It never touches Supabase and uses no OAuth redirect/callback. Failures are
// classified by SHAPE into a reviewed code — never a provider message.

import { NextResponse } from 'next/server';

export const dynamic = 'force-dynamic';

const WEB_APP_VERSION = 'web-127';

function backendUrl(): string {
  return process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
}

export async function POST(request: Request): Promise<NextResponse> {
  let body: { credential?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ outcome: 'sign_in_failed' }, { status: 200 });
  }

  const idToken = typeof body.credential === 'string' ? body.credential : '';
  if (!idToken) {
    return NextResponse.json({ outcome: 'sign_in_failed' }, { status: 200 });
  }

  let session: { api_token?: string; plan?: string } | null = null;
  try {
    const res = await fetch(`${backendUrl()}/v1/auth/google/web`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id_token: idToken, app_version: WEB_APP_VERSION }),
      cache: 'no-store',
    });
    if (res.ok) {
      session = (await res.json()) as { api_token?: string; plan?: string };
    } else {
      const outcome =
        res.status === 429 ? 'rate_limited'
        : res.status >= 500 ? 'unavailable'
        : 'sign_in_failed';
      return NextResponse.json({ outcome }, { status: 200 });
    }
  } catch {
    return NextResponse.json({ outcome: 'unavailable' }, { status: 200 });
  }

  if (!session?.api_token) {
    return NextResponse.json({ outcome: 'sign_in_failed' }, { status: 200 });
  }

  const res = NextResponse.json({ outcome: 'signed_in' }, { status: 200 });
  res.cookies.set('tono_api_token', session.api_token, {
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
  });
  res.cookies.set('tono_plan', session.plan || 'free', {
    httpOnly: false,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
  });
  return res;
}
