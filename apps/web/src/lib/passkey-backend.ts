// Server-only helpers shared by the /api/passkey/* proxy routes.
//
// The canonical backend's passkey ceremonies (register/verify, login/verify)
// all authenticate with a device bearer token. On the web that token lives in
// the httpOnly `tono_api_token` cookie, which browser JS cannot read — so every
// passkey call has to be proxied server-side, injecting the bearer as an
// Authorization header. This module is the single place that resolves the
// backend origin and the bearer so the routes stay thin and consistent.

import 'server-only';
import { cookies } from 'next/headers';

export const TONO_API_TOKEN_COOKIE = 'tono_api_token';
export const TONO_PLAN_COOKIE = 'tono_plan';
// Short-lived cookie holding the anonymous device bearer minted at the start of
// a standalone passkey login, before we know which account it belongs to. It is
// promoted to `tono_api_token` only after the assertion verifies.
export const TONO_PASSKEY_PENDING_COOKIE = 'tono_pk_pending';

export function backendUrl(): string {
  return process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
}

export async function sessionBearer(): Promise<string | null> {
  const store = await cookies();
  return store.get(TONO_API_TOKEN_COOKIE)?.value ?? null;
}

// Cookie attributes must match /auth/callback exactly so a passkey-established
// session is indistinguishable from an OAuth/magic-link one.
export const SESSION_COOKIE_OPTS = {
  httpOnly: true,
  secure: true,
  sameSite: 'lax' as const,
  path: '/',
  maxAge: 60 * 60 * 24 * 365,
};

export const PLAN_COOKIE_OPTS = {
  httpOnly: false,
  secure: true,
  sameSite: 'lax' as const,
  path: '/',
  maxAge: 60 * 60 * 24 * 365,
};

// Pending device bearer: httpOnly, short TTL — it only has to survive the round
// trip through the authenticator prompt (challenge TTL is 5 min server-side).
export const PENDING_COOKIE_OPTS = {
  httpOnly: true,
  secure: true,
  sameSite: 'lax' as const,
  path: '/',
  maxAge: 60 * 10,
};

export async function backendFetch(
  path: string,
  init: RequestInit & { bearer?: string | null } = {}
): Promise<Response> {
  const { bearer, headers, ...rest } = init;
  const h = new Headers(headers);
  h.set('Content-Type', 'application/json');
  if (bearer) h.set('Authorization', `Bearer ${bearer}`);
  return fetch(`${backendUrl()}${path}`, { ...rest, headers: h, cache: 'no-store' });
}
