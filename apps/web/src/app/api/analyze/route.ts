// Authenticated /v1/analyze proxy.
//
// Browser sends the request with the tono_api_token httpOnly cookie.
// We forward to the backend with that token as a bearer, so the
// server-side rate limiter (FREE_DAILY_LIMIT) applies per user.
//
// If the user is not logged in (no cookie), we fall back to the public
// /v1/analyze (no rate limit, no LLM key) — keeps the page usable
// before OAuth round-trips in some flows.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function POST(request: Request) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.text !== 'string' || !body.text.trim()) {
    return NextResponse.json({ error: 'text is required' }, { status: 400 });
  }

  const token = cookies().get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    // Anonymous fallback — public endpoint, no rate limit, uses
    // TONO_PROVIDER on the backend (mock by default — cheap).
    const res = await fetch(`${backendUrl}/v1/analyze`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        draft: body.text,
        axes: ['warmer', 'clearer', 'funnier', 'safer'],
      }),
      cache: 'no-store',
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  }

  // Authenticated — hit /api/analyze with bearer token.
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
    // Forward the rate-limit body verbatim so the UI can show "N/10 today".
    const data = await res.json();
    return NextResponse.json(data, {
      status: 429,
      headers: { 'Retry-After': res.headers.get('Retry-After') || '86400' },
    });
  }

  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}