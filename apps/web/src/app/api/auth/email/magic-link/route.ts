// POST /api/auth/email/magic-link — send a Tono-branded magic-link sign-in.
//
// Proxies to the canonical backend instead of calling the auth provider from
// the browser. The former browser-direct `supabase.auth.signInWithOtp` path is
// removed because it (a) sent the shared tenant's ParentScript-branded email and
// (b) used `shouldCreateUser: true`, minting unledgered provider accounts — the
// "second, unledgered path" the canonical-backend design forbids. The backend
// sends a Tono-owned branded link and, enforcing existing-users-only against
// Tono's ledger, creates nothing for an unknown address. Anti-enumerating: the
// status and body are identical whether or not the address is known.

import { NextResponse } from 'next/server';

import { looksLikeEmail } from '@/lib/email-auth';
import { callEmailAuth, currentBearer } from '@/lib/email-auth-server';

export async function POST(request: Request) {
  let body: { email?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  const email = typeof body.email === 'string' ? body.email.trim() : '';
  if (!looksLikeEmail(email)) {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  const bearer = await currentBearer();
  const { outcome } = await callEmailAuth(
    '/v1/auth/email/magic-link',
    { email },
    'check_your_email',
    bearer
  );

  return NextResponse.json({ outcome }, { status: 200 });
}
