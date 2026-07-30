import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';

export async function POST(request: Request) {
  const token = (await cookies()).get('tono_api_token')?.value;
  if (!token) return NextResponse.json({ outcome: 'sign_in_required' }, { status: 401 });

  let code = '';
  try {
    const body = (await request.json()) as { code?: unknown };
    code = typeof body.code === 'string' ? body.code.trim() : '';
  } catch {}
  if (!code) return NextResponse.json({ outcome: 'invalid' }, { status: 400 });

  try {
    const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
    const response = await fetch(`${backendUrl}/v1/coupon/redeem`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ code }),
      cache: 'no-store',
    });
    return NextResponse.json(
      { outcome: response.ok ? 'accepted' : response.status === 409 ? 'already_used' : 'invalid' },
      { status: response.status },
    );
  } catch {
    return NextResponse.json({ outcome: 'unavailable' }, { status: 502 });
  }
}
