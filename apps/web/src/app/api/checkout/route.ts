// Authenticated /v1/checkout proxy.
//
// Money must bind to a canonical account. The Pro Subscribe button POSTs
// here; we require the browser's backend bearer (the httpOnly `tono_api_token`
// cookie minted by /auth/callback via /v1/auth/web) and forward it to the
// FastAPI backend, which sets the Stripe session's client_reference_id and
// account metadata from that bearer. A request with no bearer returns
// { error: 'auth-required' } with 401 so the client redirects to login —
// the backend also refuses anonymous checkout, so no Stripe session can ever
// be created without an account behind it.
//
// CSRF/origin: a state-changing POST that spends money must be same-origin.
// We reject requests whose Origin header doesn't match this deployment's
// canonical/public origin (or the request's own origin), so a third-party
// page can't drive a logged-in user's browser into checkout.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { BASE_PATH, resolvePublicOrigin } from '@/lib/auth-redirects';

function isSameOriginRequest(request: Request): boolean {
  const origin = request.headers.get('origin');
  // No Origin header at all (e.g. same-origin GET-style navigations) — a
  // browser fetch POST always sends Origin, so treat a missing one on this
  // POST as suspicious and reject.
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
    // Not signed in — the browser has no account to bind money to.
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }

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

  // The web app owns its own return URLs. The backend's default success_url
  // (`{PUBLIC_BASE_URL}/welcome-pro`) does NOT carry this app's `/app` basePath,
  // so it would 404. Send explicit, same-origin, basePath-aware URLs pointing at
  // the real canonical post-checkout page (/app/welcome-pro) and back to pricing
  // on cancel.
  const publicOrigin = resolvePublicOrigin(undefined, process.env);
  const successUrl = `${publicOrigin}${BASE_PATH}/welcome-pro?s=1`;
  const cancelUrl = `${publicOrigin}${BASE_PATH}/pricing`;

  let res: Response;
  try {
    res = await fetch(`${backendUrl}/v1/checkout`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        interval,
        success_url: successUrl,
        cancel_url: cancelUrl,
      }),
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
