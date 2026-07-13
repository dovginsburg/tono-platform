// Returns plan + daily usage for the current user (via tono_api_token cookie).
// Falls back to {plan: 'free', used_today: 0, daily_limit: -1} if anonymous.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function GET() {
  const token = cookies().get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    return NextResponse.json({
      device_id: null,
      plan: 'free',
      is_pro: false,
      used_today: 0,
      daily_limit: -1,
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