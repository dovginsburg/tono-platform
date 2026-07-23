// Supabase OAuth + magic-link callback.
//
// Flow:
//   1. Provider (Apple/Google) returns the user to /auth/callback?code=...
//      (Supabase configured with `redirect_to=https://tonoit.com/app/auth/callback`)
//   2. We exchange the code for a Supabase session via @supabase/ssr, which
//      sets the Supabase auth cookies on the response.
//   3. Server-side, we forward the *verified* Supabase access token to the
//      canonical backend at POST /v1/auth/web. The backend verifies the JWT
//      cryptographically (issuer/JWKS/audience), resolves the ONE canonical
//      account keyed by the Supabase user id, registers a random per-browser
//      device, and returns a normal backend bearer.
//   4. We store that bearer in an httpOnly, secure, sameSite cookie and
//      redirect to /app/app.
//
// Why converge through /v1/auth/web (not /v1/register with `web:<uid>`): the
// old path minted an anonymous device keyed by the Supabase user id and never
// presented the Supabase identity to canonical auth — so the same person split
// into separate web/iOS accounts and a second browser could 409. Going through
// /v1/auth/web means the browser presents a verified identity and the backend
// converges every browser/device for that person onto one account_id.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import { createServerSupabase } from '@/lib/supabase';
import {
  APP_ENTRY_PATH,
  buildAppRedirect,
  buildLoginRedirect,
  sanitizeNextPath,
} from '@/lib/auth-redirects';

export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');
  const next = sanitizeNextPath(url.searchParams.get('next'));
  const error_description = url.searchParams.get('error_description');

  if (error_description) {
    return NextResponse.redirect(buildLoginRedirect(next, process.env, error_description));
  }

  if (code) {
    const supabase = await createServerSupabase();
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      return NextResponse.redirect(buildLoginRedirect(next, process.env, error.message));
    }

    // Exchange the verified Supabase access token for a canonical backend
    // bearer. Server-side only — the Supabase token and the backend bearer
    // never enter the client bundle.
    const accessToken = data.session?.access_token;
    if (accessToken) {
      try {
        const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
        const res = await fetch(`${backendUrl}/v1/auth/web`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ access_token: accessToken }),
          cache: 'no-store',
        });
        if (res.ok) {
          const session = (await res.json()) as {
            api_token?: string;
            account_id?: string;
            plan?: string;
          };
          if (session.api_token) {
            const cookieStore = await cookies();
            // httpOnly so the browser can hit /api/analyze and /api/checkout
            // via the server without re-minting; never readable from JS (XSS).
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
          // Don't hard-block login on a backend hiccup — the user can still
          // browse; the editor/checkout surfaces the auth-required state.
          console.error('[auth/callback] /v1/auth/web failed:', res.status, await res.text());
        }
      } catch (e) {
        console.error('[auth/callback] web sign-in error:', e);
      }
    }

    return NextResponse.redirect(buildAppRedirect(next));
  }

  // No code, no error — bounce to login
  return NextResponse.redirect(buildLoginRedirect(APP_ENTRY_PATH));
}
