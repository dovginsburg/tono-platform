// POST /api/auth/password — finish a password reset.
//
// This is the step Build 114 shipped without. Both mobile clients tell people
// "open the link we sent to choose a new password", the backend duly asked the
// provider to mail one, and the link landed on a callback that signed them into
// the website and redirected them into the app. No password field was ever
// shown, their password never changed, and they went back to the app still
// locked out with nothing left to try.
//
// The update runs SERVER-side against the recovery session the callback
// established, for two reasons: the new password never becomes a value in the
// page's own JavaScript beyond the request that submits it, and the provider's
// failure — which is free-form text naming projects and rules — is classified
// by status and never travels to the browser.
//
// Every decision about what the person is told lives in `resolvePasswordUpdate`
// so a test can execute it. What is left here is I/O.

import { NextResponse } from 'next/server';

import { resolvePasswordUpdate } from '@/lib/email-auth';
import { createServerSupabase } from '@/lib/supabase';

export async function POST(request: Request) {
  let body: { password?: unknown; confirmation?: unknown };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ outcome: 'invalid_input' }, { status: 200 });
  }

  const password = typeof body.password === 'string' ? body.password : '';
  const confirmation = typeof body.confirmation === 'string' ? body.confirmation : '';

  // Decided before any I/O, so a password the person did not mean to set never
  // spends their single-use recovery session.
  const local = resolvePasswordUpdate({ password, confirmation, hasSession: true });
  if (local !== 'password_updated') {
    return NextResponse.json({ outcome: local }, { status: 200 });
  }

  try {
    const supabase = await createServerSupabase();
    const { data, error: sessionError } = await supabase.auth.getUser();
    const hasSession = !sessionError && !!data?.user;

    let updateError: unknown = null;
    if (hasSession) {
      ({ error: updateError } = await supabase.auth.updateUser({ password }));
    }

    return NextResponse.json(
      { outcome: resolvePasswordUpdate({ password, confirmation, hasSession, updateError }) },
      { status: 200 }
    );
  } catch {
    // Deliberately does not inspect the caught failure: its message carries the
    // request URL, and on a TLS or DNS failure the host as well.
    return NextResponse.json({ outcome: 'unavailable' }, { status: 200 });
  }
}
