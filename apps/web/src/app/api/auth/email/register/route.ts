// POST /api/auth/email/register — create an account with an email and password.
//
// Proxies to the canonical backend rather than calling the auth provider from
// the browser, so a web registration is the same event a native one is: bound
// to a canonical account, written to the one registration ledger, and answered
// with the same anti-enumerating shape. The password reaches this server and
// the backend and goes no further into the page.

import { NextResponse } from 'next/server';

import { looksLikeEmail, MIN_PASSWORD_LENGTH } from '@/lib/email-auth';
import { callEmailAuth, currentBearer } from '@/lib/email-auth-server';

export async function POST(request: Request) {
  let body: { email?: unknown; password?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  const email = typeof body.email === 'string' ? body.email.trim() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  if (!looksLikeEmail(email) || password.length < MIN_PASSWORD_LENGTH) {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  // Forwarded when present so someone who registers an address while already
  // holding a canonical session upgrades THAT account in place.
  const bearer = await currentBearer();
  const { outcome } = await callEmailAuth(
    '/v1/auth/email/register',
    { email, password },
    'check_your_email',
    bearer
  );

  // Always 200: the STATUS of this route must not vary with whether the
  // address is registered, or the response code itself becomes the oracle the
  // body is careful not to be.
  return NextResponse.json({ outcome }, { status: 200 });
}
