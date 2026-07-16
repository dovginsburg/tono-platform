// Returns plan + entitlement status for the current user.

import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function GET() {
  const cookieStore = await cookies();
  const token = cookieStore.get('tono_api_token')?.value;
  const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';

  if (!token) {
    return NextResponse.json({
      device_id: null,
      plan: 'free',
      is_pro: false,
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