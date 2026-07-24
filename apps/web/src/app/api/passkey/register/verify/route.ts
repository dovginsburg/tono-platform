// POST /api/passkey/register/verify — finish adding a passkey. Forwards the
// authenticator attestation to the backend with the session bearer; the backend
// verifies the challenge, RP ID/origin, and stores the public key + sign count.

import { NextResponse } from 'next/server';
import { backendFetch, sessionBearer } from '@/lib/passkey-backend';

export async function POST(request: Request) {
  const bearer = await sessionBearer();
  if (!bearer) {
    return NextResponse.json({ error: 'auth-required' }, { status: 401 });
  }
  const body = await request.text();
  const res = await backendFetch('/v1/auth/passkey/register/verify', {
    method: 'POST',
    bearer,
    body,
  });
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { 'Content-Type': 'application/json' },
  });
}
