// POST /api/auth/email/resend — send the confirmation link again.
//
// Answers identically for a registered address, an unregistered one, and an
// already-confirmed one. "I never got the email" is the single most common
// thing to go wrong in a signup, and it must not be answerable only by people
// who already have an account.

import { NextResponse } from 'next/server';

import { looksLikeEmail } from '@/lib/email-auth';
import { callEmailAuth } from '@/lib/email-auth-server';

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

  const { outcome } = await callEmailAuth(
    '/v1/auth/email/resend',
    { email },
    'check_your_email'
  );
  return NextResponse.json({ outcome }, { status: 200 });
}
