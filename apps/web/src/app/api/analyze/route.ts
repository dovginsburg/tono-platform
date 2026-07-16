// Authenticated /v1/analyze proxy.
//
// Browser sends the request with the tono_api_token httpOnly cookie.
// We forward to the backend with that token as a bearer. Anonymous browser
// requests fail closed rather than bypassing subscription access through the
// public compatibility endpoint.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function POST(request: Request) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.text !== 'string' || !body.text.trim()) {
    return NextResponse.json({ error: 'text is required' }, { status: 400 });
  }

  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    return NextResponse.json(
      { error: { code: 429, message: 'active trial or subscription required' } },
      { status: 429 }
    );
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
    const data = await res.json();
    return NextResponse.json(data, { status: 429 });
  }

  const data = await res.json();
  return NextResponse.json(data, { status: res.status });
}