// POST /api/auth/email/login — sign in with an email and password.
//
// Two things have to become true for a person to be signed in on the website,
// and this route does them in a deliberate order:
//
//   1. The CANONICAL backend authenticates them. That call owns the two
//      verification gates (the provider must accept the credentials AND
//      consider the address confirmed; the returned token is then re-verified
//      cryptographically), the canonical account resolution, the registration
//      ledger, and the truthful entitlement projection. It is the authority,
//      so it goes first and a refusal from it ends the request.
//
//   2. Only then does a provider session get established for this browser,
//      because the signed-in app surface gates on one.
//
// Doing it in that order is what stops a project with email confirmations
// switched off from becoming a way in through the website that the native
// clients refuse: the backend's own gate has already said no by then.

import { NextResponse } from 'next/server';

import { looksLikeEmail } from '@/lib/email-auth';
import { classifyProviderFailure } from '@/lib/email-auth';
import { callEmailAuth, storeCanonicalSession, currentBearer } from '@/lib/email-auth-server';
import { createServerSupabase } from '@/lib/supabase';

export async function POST(request: Request) {
  let body: { email?: unknown; password?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  const email = typeof body.email === 'string' ? body.email.trim() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  if (!looksLikeEmail(email) || !password) {
    return NextResponse.json({ outcome: 'invalid_credentials' }, { status: 200 });
  }

  const bearer = await currentBearer();
  const { outcome, session } = await callEmailAuth(
    '/v1/auth/email/login',
    { email, password },
    'signed_in',
    bearer
  );
  if (outcome !== 'signed_in' || !session?.api_token) {
    return NextResponse.json({ outcome }, { status: 200 });
  }

  await storeCanonicalSession(session);

  // The provider session the signed-in surface gates on. The canonical backend
  // has already accepted these credentials and confirmed the address, so this
  // cannot admit anyone the authority just refused.
  try {
    const supabase = await createServerSupabase();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      // The canonical half succeeded, so the person genuinely is who they say.
      // Report by SHAPE and let them retry rather than inventing a success
      // they cannot use — the app surface would bounce them straight back.
      return NextResponse.json(
        { outcome: classifyProviderFailure(error) },
        { status: 200 }
      );
    }
  } catch {
    return NextResponse.json({ outcome: 'unavailable' }, { status: 200 });
  }

  return NextResponse.json({ outcome: 'signed_in' }, { status: 200 });
}
