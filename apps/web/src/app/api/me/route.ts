// Returns plan + entitlement for the current user (via tono_api_token cookie).
// Anonymous callers are NOT entitled: there is no free tier, so we fail closed
// with daily_limit: 0 (a zero allowance), never -1/unlimited. -1 means unlimited
// and is reserved for a genuinely entitled (Pro/trial) caller from the backend.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function GET() {
  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    return NextResponse.json({
      device_id: null,
      plan: 'anonymous',
      is_pro: false,
      used_today: 0,
      daily_limit: 0,
    });
  }

  try {
    const res = await fetch(`${backendUrl}/v1/me`, {
      headers: { Authorization: `Bearer ${token}` },
      cache: 'no-store',
    });
    const data = await res.json();
    return NextResponse.json(data, { status: res.status });
  } catch {
    return NextResponse.json({ error: 'failed to load plan' }, { status: 502 });
  }
}