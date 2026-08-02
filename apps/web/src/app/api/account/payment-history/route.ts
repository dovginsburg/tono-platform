// Returns the signed-in account's payment/billing timeline (via the
// tono_api_token httpOnly cookie). This is a thin authenticated proxy to the
// backend's owner-scoped /v1/account/payment-history — the browser never sees
// the bearer, and there is no account-id parameter, so one person can never
// request another's billing. Anonymous callers fail closed with an empty
// timeline (never a fabricated purchase and never another account's rows).

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function GET() {
  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    return NextResponse.json(
      { account_id: null, plan: 'anonymous', is_pro: false, items: [] },
      { status: 200 },
    );
  }

  try {
    const res = await fetch(`${backendUrl}/v1/account/payment-history`, {
      headers: { Authorization: `Bearer ${token}` },
      cache: 'no-store',
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch {
    // A backend fault is surfaced as an explicit error, never as a silent empty
    // timeline (which would misreport a paying customer as never having paid).
    return NextResponse.json({ error: 'failed to load payment history' }, { status: 502 });
  }
}
