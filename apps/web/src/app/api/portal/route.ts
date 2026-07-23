// Authenticated /v1/portal proxy — opens the Stripe billing portal so a signed-in
// user can view their subscription, update their card, or cancel. Mirrors the
// /api/checkout proxy exactly: same-origin CSRF guard + the httpOnly
// `tono_api_token` bearer minted at /auth/callback. A request with no bearer
// returns 401 auth-required so the client can send the visitor to sign in.
//
// The backend refuses to open a portal for a customer with no Stripe record
// on file (400) — a user who has never checked out has nothing to manage.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { BASE_PATH, resolvePublicOrigin } from '@/lib/auth-redirects';

function isSameOriginRequest(request: Request): boolean {
  const origin = request.headers.get('origin');
  if (!origin) return false;
  const allowed = new Set<string>();
  try {
    allowed.add(new URL(request.url).origin);
  } catch {
    // ignore malformed request URL
  }
  const publicOrigin = resolvePublicOrigin(undefined, process.env);
  if (publicOrigin) allowed.add(publicOrigin);
  return allowed.has(origin);
}

export async function POST(request: Request) {
  if (!isSameOriginRequest(request)) {
    return NextResponse.json({ error: 'forbidden origin' }, { status: 403 });
  }

  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  if (!token) {
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }

  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
  const publicOrigin = resolvePublicOrigin(undefined, process.env);
  const returnUrl = `${publicOrigin}${BASE_PATH}/account`;

  let res: Response;
  try {
    res = await fetch(`${backendUrl}/v1/portal`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ return_url: returnUrl }),
      cache: 'no-store',
    });
  } catch {
    return NextResponse.json({ error: "couldn't reach billing" }, { status: 502 });
  }

  let data: unknown = null;
  try {
    data = await res.json();
  } catch {
    // non-json body — pass through as opaque error
  }

  return NextResponse.json(data ?? {}, { status: res.status });
}
