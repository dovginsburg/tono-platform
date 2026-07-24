// POST /api/passkey/register/options — begin adding a passkey to the signed-in
// account. Proxies the backend register/options ceremony, injecting the device
// bearer from the httpOnly session cookie (browser JS can't read it).

import { NextResponse } from 'next/server';
import { backendFetch, sessionBearer } from '@/lib/passkey-backend';

export async function POST() {
  const bearer = await sessionBearer();
  if (!bearer) {
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }
  const res = await backendFetch('/v1/auth/passkey/register/options', {
    method: 'POST',
    bearer,
    body: '{}',
  });
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
