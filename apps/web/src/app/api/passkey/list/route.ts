// GET /api/passkey/list — the signed-in account's registered passkeys, for the
// management UI on /app/account. Proxies to the backend with the session bearer.

import { NextResponse } from 'next/server';
import { backendFetch, sessionBearer } from '@/lib/passkey-backend';

export async function GET() {
  const bearer = await sessionBearer();
  if (!bearer) {
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }
  const res = await backendFetch('/v1/auth/passkey', { method: 'GET', bearer });
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
