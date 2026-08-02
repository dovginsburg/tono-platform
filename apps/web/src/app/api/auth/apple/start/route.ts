// Direct Tono "Sign in with Apple" — START.
//
// Begins the Apple OAuth flow the website OWNS (client_id = Tono's Services ID),
// replacing the removed Supabase Apple path. It mints a strong state + nonce,
// binds them to this browser in short-lived HttpOnly cookies, and redirects to
// Apple's authorize endpoint. It fails CLOSED: if the server-side boundary is
// not fully configured (team id / key id / Tono Services id / private key), it
// never starts a flow — it bounces to /login with a reviewed code. So a stray
// hit can never produce a half-configured redirect to Apple.

import { NextResponse } from 'next/server';
import {
  readAppleWebConfig,
  buildAppleAuthorizeUrl,
  randomToken,
  STATE_COOKIE,
  NONCE_COOKIE,
  NEXT_COOKIE,
} from '@/lib/apple-web-auth';
import { buildLoginRedirect, sanitizeNextPath, APP_ENTRY_PATH } from '@/lib/auth-redirects';

// Never cache: every start must mint a fresh state/nonce pair.
export const dynamic = 'force-dynamic';

export async function GET(request: Request): Promise<NextResponse> {
  const url = new URL(request.url);
  const next = sanitizeNextPath(url.searchParams.get('next'));

  const config = readAppleWebConfig(process.env);
  if (!config) {
    // Fail closed — the boundary is not configured on this deployment.
    return NextResponse.redirect(buildLoginRedirect(next, process.env, 'unavailable'));
  }

  const state = randomToken();
  const nonce = randomToken();

  const authorizeUrl = buildAppleAuthorizeUrl({
    clientId: config.clientId,
    redirectUri: config.redirectUri,
    state,
    nonce,
  });

  const res = NextResponse.redirect(authorizeUrl);

  // Transaction cookies bind this browser to this exact request.
  //   * httpOnly  — no script can read the state/nonce (XSS-proof).
  //   * secure    — https only.
  //   * SameSite=None — REQUIRED: Apple returns via a cross-site top-level POST
  //     (response_mode=form_post), on which SameSite=Lax cookies are NOT sent.
  //     CSRF is defended by the state double-submit check on the callback, not
  //     by SameSite, so None is safe here.
  //   * short maxAge, path '/' so the cookie reaches the callback whether Apple
  //     posts to the apex or the /app basePath form of the return URL.
  const base = {
    httpOnly: true,
    secure: true,
    sameSite: 'none' as const,
    path: '/',
    maxAge: 600, // 10 min — a login round-trip, no more.
  };
  res.cookies.set(STATE_COOKIE, state, base);
  res.cookies.set(NONCE_COOKIE, nonce, base);
  // `next` is already same-origin-sanitized; carry it so the callback lands the
  // person where they were headed. Defaulted so the cookie is always present.
  res.cookies.set(NEXT_COOKIE, next || APP_ENTRY_PATH, base);

  return res;
}
