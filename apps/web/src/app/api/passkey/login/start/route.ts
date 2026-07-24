// POST /api/passkey/login/start — begin a STANDALONE passkey sign-in (no
// existing session). A fresh browser has no device bearer, and the backend's
// login/verify requires one, so we:
//   1. mint an anonymous per-browser device via /v1/register (public, no auth),
//   2. stash that bearer in a short-lived httpOnly cookie (tono_pk_pending),
//   3. fetch the public login/options challenge and hand it to the browser.
// The bearer is only promoted to a real session in login/finish, after the
// authenticator assertion actually verifies — so nothing is granted here.

import { NextResponse } from 'next/server';
import {
  backendFetch,
  PENDING_COOKIE_OPTS,
  TONO_PASSKEY_PENDING_COOKIE,
} from '@/lib/passkey-backend';

export async function POST() {
  // 1. Mint an anonymous device.
  const reg = await backendFetch('/v1/register', {
    method: 'POST',
    body: JSON.stringify({ platform: 'web' }),
  });
  if (!reg.ok) {
    return NextResponse.json(
      { error: 'device-register-failed' },
      { status: 503 }
    );
  }
  const session = (await reg.json()) as { api_token?: string };
  if (!session.api_token) {
    return NextResponse.json({ error: 'device-register-failed' }, { status: 503 });
  }

  // 3. Public login options (challenge). Discoverable credentials — the
  // authenticator itself lets the user pick which passkey.
  const opts = await backendFetch('/v1/auth/passkey/login/options', {
    method: 'POST',
    body: '{}',
  });
  const text = await opts.text();
  const response = new NextResponse(text, {
    status: opts.status,
    headers: { 'Content-Type': 'application/json' },
  });
  // 2. Stash the pending device bearer alongside the challenge response.
  if (opts.ok) {
    response.cookies.set(
      TONO_PASSKEY_PENDING_COOKIE,
      session.api_token,
      PENDING_COOKIE_OPTS
    );
  }
  return response;
}
