// Authenticated /v1/checkout proxy.
//
// The marketing Pro Subscribe button POSTs here. We forward to the
// FastAPI backend. The API token binds the explicitly authorized Stripe
// subscription to the signed-in Tono identity for webhook reconciliation.
//
// The backend returns { url, session_id } on 200. We pass them
// through unchanged so the client can redirect via window.location.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';

export async function POST(request: Request) {
  let body: { interval?: string };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: 'invalid json' }, { status: 400 });
  }

  const interval = body?.interval;
  if (interval !== 'month' && interval !== 'year') {
    return NextResponse.json(
      { error: 'interval must be "month" or "year"' },
      { status: 400 }
    );
  }

  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
  const token = (await cookies()).get('tono_api_token')?.value;
  if (!token) {
    return NextResponse.json(
      { error: 'sign in before starting your trial' },
      { status: 401 }
    );
  }

  let res: Response;
  try {
    res = await fetch(`${backendUrl}/v1/checkout`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ interval }),
      cache: 'no-store',
    });
  } catch (err) {
    return NextResponse.json(
      { error: "couldn't reach checkout" },
      { status: 502 }
    );
  }

  let data: unknown = null;
  try {
    data = await res.json();
  } catch {
    // non-json body — pass through as opaque error
  }

  return NextResponse.json(data ?? {}, { status: res.status });
}
