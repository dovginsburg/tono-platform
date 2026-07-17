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

    // Mint a stable backend device credential, then link it to the Supabase
    // identity through a server-to-server authenticated endpoint.
    try {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user?.id) {
        const backendUrl = process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
        const webAuthSecret =
          process.env.TONO_WEB_AUTH_SECRET || process.env.TONO_BACKEND_ADMIN_SECRET || '';
        const cookieStore = await cookies();
        const existingDeviceId = cookieStore.get('tono_device_id')?.value;
        const existingCredential = cookieStore.get('tono_device_credential')?.value;

        const register = (reuseExisting: boolean) =>
          fetch(`${backendUrl}/v1/register`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              platform: 'web',
              device_id: reuseExisting ? existingDeviceId : undefined,
              device_credential: reuseExisting ? existingCredential : undefined,
            }),
            cache: 'no-store',
          });

        let reg = await register(Boolean(existingDeviceId && existingCredential));
        if (!reg.ok && existingDeviceId) {
          // Legacy web sessions did not retain registration proof. Create a
          // fresh proved device rather than bypassing device ownership checks.
          reg = await register(false);
        }
        if (reg.ok) {
          const registration = (await reg.json()) as {
            api_token?: string;
            device_id?: string;
            device_credential?: string;
          };
          if (registration.api_token && registration.device_id && webAuthSecret) {
            const linked = await fetch(`${backendUrl}/v1/auth/web`, {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                Authorization: `Bearer ${registration.api_token}`,
                'X-Web-Auth-Secret': webAuthSecret,
              },
              body: JSON.stringify({ subject: user.id, email: user.email || null }),
              cache: 'no-store',
            });
            if (linked.ok) {
              const account = (await linked.json()) as { plan?: string };
              const oneYear = 60 * 60 * 24 * 365;
              cookieStore.set('tono_api_token', registration.api_token, {
                httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge: oneYear,
              });
              cookieStore.set('tono_device_id', registration.device_id, {
                httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge: oneYear,
              });
              if (registration.device_credential) {
                cookieStore.set('tono_device_credential', registration.device_credential, {
                  httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge: oneYear,
                });
              }
              cookieStore.set('tono_plan', account.plan || 'unpaid', {
                httpOnly: false, secure: true, sameSite: 'lax', path: '/', maxAge: oneYear,
              });
            } else {
              console.error('[auth/callback] /v1/auth/web failed:', linked.status, await linked.text());
            }
          } else {
            console.error('[auth/callback] missing registration fields or TONO_WEB_AUTH_SECRET');
          }
        } else {
          console.error('[auth/callback] /v1/register failed:', reg.status, await reg.text());
        }
      }
    } catch (e) {
      console.error('[auth/callback] account link error:', e);
    }

    return NextResponse.redirect(buildAppRedirect(next));
  }

  // No code, no error — bounce to login
  return NextResponse.redirect(buildLoginRedirect(APP_ENTRY_PATH));
}
