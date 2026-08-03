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
  buildAppRedirect,
  buildLoginRedirect,
  buildResetRedirect,
  isRecoveryCallback,
  sanitizeNextPath,
} from '@/lib/auth-redirects';
import { FRAGMENT_BOUNCE_HTML } from '@/lib/auth-complete';

export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');
  const next = sanitizeNextPath(url.searchParams.get('next'));
  const error_description = url.searchParams.get('error_description');
  // Build 114 remediation — a recovery link must end at the screen where a new
  // password is chosen, not in the editor. Read before the exchange so the
  // failure paths below can route a dead recovery link to the same place a
  // dead sign-in link goes, with copy that offers another one.
  const recovery = isRecoveryCallback(url.searchParams);

  // Build 114 — a provider's own `error_description` is never forwarded. It is
  // free-form provider text (hosts, projects, internal reasons) and it differs
  // for a known and an unknown address, so passing it on would both leak
  // implementation detail and turn this URL into an enumeration oracle. The
  // presence of a failure is all that travels; the login page owns the words.
  if (error_description) {
    return NextResponse.redirect(buildLoginRedirect(next, process.env, 'sign_in_failed'));
  }

  if (code) {
    const supabase = await createServerSupabase();
    const { data, error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      // Classified by STATUS, never by message. An expired or already-used link
      // is the common case and has its own next step ("ask for a new one"),
      // which is worth keeping distinct from a generic failure.
      const status = (error as { status?: number }).status;
      const reason =
        status === 429 ? 'rate_limited'
        : status === 403 || status === 401 || status === 410 ? 'link_expired'
        : typeof status === 'number' && status >= 500 ? 'unavailable'
        : 'sign_in_failed';
      return NextResponse.redirect(buildLoginRedirect(next, process.env, reason));
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
          // Build 114 — `app_version` tags this registration on the same ledger
          // the native surfaces write to, so the web population is countable and
          // auditable instead of invisible. A build tag, not an identifier.
          body: JSON.stringify({ access_token: accessToken, app_version: 'web-114' }),
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
          // Don't hard-block login on a hiccup — the user can still browse; the
          // editor/checkout surfaces the auth-required state.
          //
          // Build 114 — the response BODY is no longer logged. On success it
          // contains `api_token`, and a 4xx/5xx body can echo the request, so
          // this line was capable of writing a live bearer (and, on some
          // failures, the address) into the server log. The status code is the
          // only part that is both useful for diagnosis and safe to keep.
          console.error('[auth/callback] canonical sign-in rejected, status:', res.status);
        }
      } catch {
        // Deliberately does not log the caught failure: its message carries the
        // request URL, and on a TLS or DNS failure the host as well. That a
        // sign-in could not be completed is the whole diagnosable fact here.
        console.error('[auth/callback] canonical sign-in could not be completed');
      }
    }

    // A recovery link has one destination and it is not the editor: the person
    // was told they would get to choose a new password, and the session just
    // established is what authorises them to. Sending them anywhere else is the
    // defect — their password would be unchanged and they would still be locked
    // out of the app they started from, with nothing left to try.
    return NextResponse.redirect(recovery ? buildResetRedirect() : buildAppRedirect(next));
  }

  // No `?code` and no `?error_description` reached the server. For OAuth/PKCE
  // that is an empty callback → sign-in. But the backend-brokered email links
  // (register / resend / reset) land HERE with their session in the URL
  // FRAGMENT, which the server cannot see — so instead of bouncing blindly to
  // login and stranding every verification and every password reset, serve a
  // small document that reads the fragment in the browser and posts it to
  // /api/auth/email/complete, the server half that adopts the session and routes
  // a recovery to the password screen. See src/lib/auth-complete.ts.
  return new NextResponse(FRAGMENT_BOUNCE_HTML, {
    status: 200,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'x-robots-tag': 'noindex',
    },
  });
}
