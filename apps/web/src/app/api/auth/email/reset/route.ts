// POST /api/auth/email/reset — start password recovery.
//
// The backend asks the auth provider to mail a recovery link whose target is
// this site's auth callback, flagged as a recovery flow. The callback then
// sends the person to /auth/reset, where they actually choose a new password.
//
// Before Build 114's remediation this request was reachable from iOS and
// Android but the link it produced signed the person into the website and
// showed them no password field, so the flow their client had just promised
// ("open the link we sent to choose a new password") could not be completed on
// any surface. This route is the web half of closing that.

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
    '/v1/auth/email/reset',
    { email },
    'check_your_email'
  );
  return NextResponse.json({ outcome }, { status: 200 });
}
