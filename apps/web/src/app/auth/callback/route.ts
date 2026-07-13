// Supabase OAuth + magic-link callback.
//
// Flow:
//   1. Provider (Apple/Google) returns the user to /auth/callback?code=...
//      (Supabase configured with `redirect_to=https://tonoit.com/app/auth/callback`)
//   2. We exchange the code for a session via @supabase/ssr, which sets
//      the auth cookies on the response.
//   3. Server-side, we call https://api.tonoit.com/v1/register to mint a
//      Tono api_token (this lets web + iOS share one Supabase user, but
//      each surface has its own Tono device/api_token).
//   4. We store api_token in an httpOnly cookie + redirect to /app/app.
//
// Why server-side register? The iOS keyboard uses /api/analyze with the
// api_token as bearer — if we mint it client-side, we'd have to either
// keep it in localStorage (XSS risk) or do this round-trip anyway. Server
// side keeps the token out of the bundle.

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
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) {
      return NextResponse.redirect(buildLoginRedirect(next, process.env, error.message));
    }

    // Mint a Tono api_token using the Supabase user_id as device_id.
    // Server-side only — never expose TONO_BACKEND_ADMIN_SECRET to client.
    try {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user?.id) {
        const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
        const adminSecret = process.env.TONO_BACKEND_ADMIN_SECRET || '';
        const reg = await fetch(`${backendUrl}/v1/register`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Admin-Secret': adminSecret,
          },
          body: JSON.stringify({ device_id: `web:${user.id}` }),
          // Don't cache; don't follow on the auth side
          cache: 'no-store',
        });
        if (reg.ok) {
          const data = (await reg.json()) as { api_token?: string; plan?: string; is_pro?: boolean };
          if (data.api_token) {
            const cookieStore = await cookies();
            // Set httpOnly cookie so the browser can hit /api/analyze via
            // the rewrite without re-minting on every request.
            cookieStore.set('tono_api_token', data.api_token, {
              httpOnly: true,
              secure: true,
              sameSite: 'lax',
              path: '/',
              maxAge: 60 * 60 * 24 * 365, // 1y; rotated on register re-call
            });
            cookieStore.set('tono_plan', data.plan || 'free', {
              httpOnly: false,
              secure: true,
              sameSite: 'lax',
              path: '/',
              maxAge: 60 * 60 * 24 * 365,
            });
          }
        } else {
          // Don't block the login if backend register fails — the user
          // can still browse; the editor will surface the issue.
          console.error('[auth/callback] /v1/register failed:', reg.status, await reg.text());
        }
      }
    } catch (e) {
      console.error('[auth/callback] register error:', e);
    }

    return NextResponse.redirect(buildAppRedirect(next));
  }

  // No code, no error — bounce to login
  return NextResponse.redirect(buildLoginRedirect(APP_ENTRY_PATH));
}