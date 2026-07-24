// POST /api/passkey/login/finish — complete a standalone passkey sign-in.
// Reads the pending anonymous device bearer, forwards the assertion to the
// backend login/verify (which checks challenge, RP ID/origin, signature, and
// the sign-count replay counter, then binds the device to the resolved
// account). ONLY on success do we promote the pending bearer to the real
// httpOnly session cookie — mirroring exactly what /auth/callback sets — so a
// forged or replayed assertion never yields a session.

import { NextResponse } from 'next/server';
import { cookies } from 'next/headers';
import {
  backendFetch,
  PLAN_COOKIE_OPTS,
  SESSION_COOKIE_OPTS,
  TONO_API_TOKEN_COOKIE,
  TONO_PASSKEY_PENDING_COOKIE,
  TONO_PLAN_COOKIE,
} from '@/lib/passkey-backend';

export async function POST(request: Request) {
  const cookieStore = await cookies();
  const pending = cookieStore.get(TONO_PASSKEY_PENDING_COOKIE)?.value;
  if (!pending) {
    return NextResponse.json(
      { error: 'no-pending-login', detail: 'start a passkey sign-in first' },
      { status: 400 }
    );
  }

  const body = await request.text();
  const res = await backendFetch('/v1/auth/passkey/login/verify', {
    method: 'POST',
    bearer: pending,
    body,
  });

  if (!res.ok) {
    // Assertion failed — discard the pending device bearer, grant nothing.
    const errText = await res.text();
    const failed = NextResponse.json(
      { error: 'passkey-verify-failed', detail: errText },
      { status: res.status === 401 ? 401 : 400 }
    );
    failed.cookies.delete(TONO_PASSKEY_PENDING_COOKIE);
    return failed;
  }

  const result = (await res.json()) as {
    account_id: string;
    plan: string;
    is_pro: boolean;
    email?: string | null;
  };

  const ok = NextResponse.json({ ok: true, plan: result.plan, is_pro: result.is_pro });
  // Promote the now-account-bound device bearer to the canonical session.
  ok.cookies.set(TONO_API_TOKEN_COOKIE, pending, SESSION_COOKIE_OPTS);
  ok.cookies.set(TONO_PLAN_COOKIE, result.plan || 'free', PLAN_COOKIE_OPTS);
  ok.cookies.delete(TONO_PASSKEY_PENDING_COOKIE);
  return ok;
}
