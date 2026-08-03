// POST /api/auth/email/complete — finish an IMPLICIT-flow email link.
//
// The register / resend / reset mail the backend brokers is followed to a link
// that lands on /auth/callback with the session in the URL FRAGMENT (see
// src/lib/auth-complete.ts for why the backend-brokered flows are implicit and
// the browser-initiated ones — OAuth, magic link — are not). The callback
// serves a tiny document that reads the fragment and posts it here. This is the
// ONE place those tokens cross back to the server, where they can (a) become the
// Supabase session cookies the password-reset screen needs and (b) mint the
// canonical backend bearer — exactly what the `?code` path already does, just
// sourced from the fragment. The response is a single reviewed REDIRECT path;
// no backend or provider sentence is ever returned to the browser.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';

import { createServerSupabase } from '@/lib/supabase';
import { isRecoveryCompletion, resolveCompleteRedirect } from '@/lib/auth-complete';

// Bound the token strings before we hand them to the provider. A Supabase access
// token is a JWT and a refresh token is short; anything longer is not a token we
// should be forwarding, and refusing early keeps a hostile body from becoming a
// provider call.
const MAX_TOKEN_LENGTH = 4096;

function asToken(value: unknown): string {
  return typeof value === 'string' && value.length > 0 && value.length <= MAX_TOKEN_LENGTH
    ? value
    : '';
}

export async function POST(request: Request) {
  let body: {
    access_token?: unknown;
    refresh_token?: unknown;
    type?: unknown;
    flow?: unknown;
    error?: unknown;
    error_code?: unknown;
    next?: unknown;
  };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({
      redirect: resolveCompleteRedirect({ hasTokens: false, sessionEstablished: false, recovery: false }),
    });
  }

  const accessToken = asToken(body.access_token);
  const refreshToken = asToken(body.refresh_token);
  const fragmentError = typeof body.error === 'string' && body.error ? body.error : null;
  const fragmentErrorCode =
    typeof body.error_code === 'string' && body.error_code ? body.error_code : null;
  const next = typeof body.next === 'string' ? body.next : null;
  const recovery = isRecoveryCompletion(
    typeof body.type === 'string' ? body.type : null,
    typeof body.flow === 'string' ? body.flow : null,
  );

  // A link that failed carries an error, not tokens — decided without any I/O.
  if (fragmentError || fragmentErrorCode) {
    return NextResponse.json({
      redirect: resolveCompleteRedirect({
        fragmentError,
        fragmentErrorCode,
        hasTokens: false,
        sessionEstablished: false,
        recovery,
        next,
      }),
    });
  }
  if (!accessToken || !refreshToken) {
    return NextResponse.json({
      redirect: resolveCompleteRedirect({ hasTokens: false, sessionEstablished: false, recovery, next }),
    });
  }

  try {
    const supabase = await createServerSupabase();
    // Adopt the session GoTrue already minted at /verify. setSession validates
    // BOTH tokens with the provider and, through the @supabase/ssr cookie
    // adapter, writes the Supabase session cookies this browser needs — which is
    // what lets the reset screen's server-side updateUser run at all.
    const { data, error } = await supabase.auth.setSession({
      access_token: accessToken,
      refresh_token: refreshToken,
    });
    if (error || !data.session) {
      const status = (error as { status?: number } | null | undefined)?.status ?? null;
      return NextResponse.json({
        redirect: resolveCompleteRedirect({
          hasTokens: true,
          sessionEstablished: false,
          sessionFailureStatus: status,
          recovery,
          next,
        }),
      });
    }

    // Mint the canonical backend bearer from the verified access token, exactly
    // as /auth/callback does for the `?code` path — so a person who finishes an
    // email link lands in the SAME signed-in state as one who used OAuth, and
    // the account they upgraded (history, usage, any purchase) follows them. A
    // hiccup here does not block the redirect: the reset screen and editor both
    // re-derive auth server-side, and recovery only needs the Supabase session
    // set above.
    try {
      const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
      const res = await fetch(`${backendUrl}/v1/auth/web`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ access_token: data.session.access_token, app_version: 'web-114' }),
        cache: 'no-store',
      });
      if (res.ok) {
        const session = (await res.json()) as { api_token?: string; plan?: string };
        if (session.api_token) {
          const cookieStore = await cookies();
          cookieStore.set('tono_api_token', session.api_token, {
            httpOnly: true,
            secure: true,
            sameSite: 'lax',
            path: '/',
            maxAge: 60 * 60 * 24 * 365, // 1y; rotated on re-auth
          });
          cookieStore.set('tono_plan', session.plan || 'free', {
            httpOnly: false,
            secure: true,
            sameSite: 'lax',
            path: '/',
            maxAge: 60 * 60 * 24 * 365,
          });
        }
      } else {
        // Status only — never the body (it carries the bearer on success and can
        // echo the request on failure). Mirrors /auth/callback.
        console.error('[auth/complete] canonical sign-in rejected, status:', res.status);
      }
    } catch {
      console.error('[auth/complete] canonical sign-in could not be completed');
    }

    return NextResponse.json({
      redirect: resolveCompleteRedirect({ hasTokens: true, sessionEstablished: true, recovery, next }),
    });
  } catch {
    // Deliberately does not inspect the caught failure: its message can carry
    // the request URL, and on a TLS/DNS failure the host. That the completion
    // could not finish is the whole diagnosable fact.
    return NextResponse.json({
      redirect: resolveCompleteRedirect({
        hasTokens: true,
        sessionEstablished: false,
        sessionFailureStatus: 500,
        recovery,
        next,
      }),
    });
  }
}
