// Authenticated /api/analyze proxy.
//
// The browser sends the request with the tono_api_token httpOnly cookie.
// We forward it to the backend's gated /api/analyze with that token as a
// bearer, so the server-side entitlement gate applies per user (fail closed
// with HTTP 402 unless the user has an active trial/subscription).
//
// There is NO free tier and NO anonymous rewrite path: a caller with no token
// is NEVER proxied to a public rewrite route. We fail closed locally with the
// same distinct 402 the backend gate would return, so the honest disclosure
// (/api/me -> daily_limit: 0 for anonymous) and the actual behavior agree.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

// Mirrors the backend's shaped entitlement error
// ({ error: { code, reason, message } }) so clients can branch on either the
// 402 status or the stable `reason` key.
const ENTITLEMENT_REQUIRED = {
  error: {
    code: 402,
    reason: 'entitlement_required',
    message: 'An active Tono trial or subscription is required to rewrite.',
  },
};

export async function POST(request: Request) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.text !== 'string' || !body.text.trim()) {
    return NextResponse.json({ error: 'text is required' }, { status: 400 });
  }

  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    // No principal -> fail closed. Never fall back to a public rewrite route.
    return NextResponse.json(ENTITLEMENT_REQUIRED, { status: 402 });
  }

  // Authenticated -> hit the gated /api/analyze with the bearer token. The
  // backend's shared entitlement gate returns a distinct 402 for a non-entitled
  // principal, and a 429 only for genuine per-IP rate limiting.
  const res = await fetch(`${backendUrl}/api/analyze`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      text: body.text,
      axes: ['warmer', 'clearer', 'funnier', 'safer'],
    }),
    cache: 'no-store',
  });

  if (res.status === 429) {
    // Forward the honest per-IP rate-limit response (no daily-quota framing;
    // there is no daily quota under the contract).
    const data = await res.json().catch(() => ({}));
    return NextResponse.json(data, {
      status: 429,
      headers: { 'Retry-After': res.headers.get('Retry-After') || '60' },
    });
  }

  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}
