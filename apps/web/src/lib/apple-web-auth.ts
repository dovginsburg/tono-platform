// Direct, Tono-owned "Sign in with Apple" for the web — the crypto/OAuth core.
//
// This module replaces the old path where the website drove Apple sign-in
// through Supabase's Apple provider. On the shared Supabase project that
// provider is bound to a SIBLING PRODUCT's Services ID, so clicking Apple sent a
// Tono user into another product's consent screen and (worse) presented that
// sibling client id to Apple. The fix is not to re-point a shared dashboard — it
// is to own the Apple OAuth boundary here, under Tono's own Services ID
// (`tonoit.com`), Team ID, key, and redirect URI.
//
// Everything here is PURE and dependency-injectable (fetch + clock + JWKS are
// parameters), so the whole boundary is unit-testable with an ephemeral P-256
// key the test generates itself — no real secret, no network, is ever needed.
// The route handlers are the only place env secrets are read; this file only
// ever receives them as arguments.
//
// It uses Node's built-in WebCrypto (`globalThis.crypto.subtle`, present in the
// Node 22 runtime these route handlers run on) for both:
//   * ES256 signing of the short-lived Apple *client secret* JWT (token
//     exchange auth), and
//   * RS256 verification of Apple's *identity token* against Apple's JWKS.
// No `jose`/`jsonwebtoken` dependency is added.

import { isTonoAppleServicesId } from './apple-oauth-binding.ts';

export const APPLE_AUTHORIZE_URL = 'https://appleid.apple.com/auth/authorize';
export const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token';
export const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
export const APPLE_ISSUER = 'https://appleid.apple.com';

// Short-lived transaction cookies that bind a browser to the OAuth request it
// started. Single-use, ~10 min. Named with the `tono_apple_` prefix so they are
// unmistakable and can be cleared as a group on the callback.
export const STATE_COOKIE = 'tono_apple_state';
export const NONCE_COOKIE = 'tono_apple_nonce';
export const NEXT_COOKIE = 'tono_apple_next';
export const TRANSACTION_COOKIES = [STATE_COOKIE, NONCE_COOKIE, NEXT_COOKIE] as const;

/** Default Apple return URL, apex form (rewritten to /app by vercel.json). */
export const DEFAULT_APPLE_WEB_REDIRECT_URI = 'https://tonoit.com/api/auth/apple/callback';

/** Reviewed, non-secret configuration for the direct Apple web boundary. */
export type AppleWebConfig = {
  /** Apple Developer Team ID — the `iss` of the client-secret JWT. */
  teamId: string;
  /** Sign in with Apple key ID — the `kid` header of the client-secret JWT. */
  keyId: string;
  /** Apple Services ID — the OAuth `client_id` / identity-token audience. */
  clientId: string;
  /** Exact Apple return URL; must match what is registered on the key. */
  redirectUri: string;
  /** PKCS#8 PEM private key for the Sign in with Apple key. SECRET. */
  privateKeyPem: string;
};

export type AppleWebEnv = {
  APPLE_WEB_TEAM_ID?: string;
  APPLE_WEB_KEY_ID?: string;
  APPLE_WEB_CLIENT_ID?: string;
  APPLE_WEB_REDIRECT_URI?: string;
  APPLE_WEB_PRIVATE_KEY?: string;
  APPLE_WEB_EXPECTED_CLIENT_ID?: string;
  // Index signature so `process.env` (and test fakes) satisfy this shape; the
  // named keys above document exactly which vars this boundary reads.
  [key: string]: string | undefined;
};

/**
 * Assemble the direct-boundary config from env, or return `null` (fail closed).
 *
 * Returns a usable config ONLY when every required secret is present AND the
 * configured `client_id` is a Tono-owned Services ID. The Tono-shape check is
 * the same allowlist the button gate uses (`isTonoAppleServicesId`): it makes a
 * copy-paste of the contaminated sibling id unable to satisfy the boundary even
 * if it were pasted into the server env. Absent or foreign config ⇒ `null`, and
 * the start route refuses to begin a flow.
 */
export function readAppleWebConfig(env: AppleWebEnv): AppleWebConfig | null {
  const teamId = (env.APPLE_WEB_TEAM_ID ?? '').trim();
  const keyId = (env.APPLE_WEB_KEY_ID ?? '').trim();
  const clientId = (env.APPLE_WEB_CLIENT_ID ?? '').trim();
  const privateKeyPem = env.APPLE_WEB_PRIVATE_KEY ?? '';
  const redirectUri = (env.APPLE_WEB_REDIRECT_URI ?? '').trim() || DEFAULT_APPLE_WEB_REDIRECT_URI;

  if (!teamId || !keyId || !clientId || !privateKeyPem.trim()) return null;

  // The client_id must be Tono-owned. An operator may pin the exact expected
  // Services ID; otherwise the reverse-DNS allowlist applies. Fail closed on a
  // foreign value so the contaminated sibling id can never drive a real flow.
  if (!isTonoAppleServicesId(clientId, env.APPLE_WEB_EXPECTED_CLIENT_ID)) return null;

  // The redirect URI must be an https URL (Apple requires it, and it prevents a
  // misconfiguration from turning into an open redirect through the token
  // exchange). Fail closed on anything else.
  try {
    const u = new URL(redirectUri);
    if (u.protocol !== 'https:') return null;
  } catch {
    return null;
  }

  return { teamId, keyId, clientId, redirectUri, privateKeyPem };
}

/** Whether the complete server-side direct boundary is configured. */
export function appleWebBoundaryConfigured(env: AppleWebEnv): boolean {
  return readAppleWebConfig(env) !== null;
}

// ---------------------------------------------------------------------------
// base64url + small encoders
// ---------------------------------------------------------------------------

export function base64UrlEncode(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlDecode(input: string): Uint8Array<ArrayBuffer> {
  const pad = input.length % 4 === 0 ? '' : '='.repeat(4 - (input.length % 4));
  const b64 = input.replace(/-/g, '+').replace(/_/g, '/') + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function encodeJson(value: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

function decodeJsonSegment<T = Record<string, unknown>>(segment: string): T {
  return JSON.parse(new TextDecoder().decode(base64UrlDecode(segment))) as T;
}

// ---------------------------------------------------------------------------
// Random state / nonce
// ---------------------------------------------------------------------------

/** A cryptographically strong, URL-safe token (32 bytes → 43 base64url chars). */
export function randomToken(size = 32): string {
  const bytes = new Uint8Array(size);
  globalThis.crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

// ---------------------------------------------------------------------------
// Authorize URL
// ---------------------------------------------------------------------------

/**
 * Build the Apple authorize URL for the direct web flow.
 *
 * `response_mode=form_post` (required whenever a scope is requested) means Apple
 * returns the result as a cross-site top-level POST to `redirect_uri`; the
 * transaction cookies must therefore be `SameSite=None; Secure` to survive that
 * POST (see `transactionCookieOptions`). CSRF is defended by the `state`
 * double-submit check, not by SameSite.
 */
export function buildAppleAuthorizeUrl(args: {
  clientId: string;
  redirectUri: string;
  state: string;
  nonce: string;
  scope?: string;
}): string {
  const url = new URL(APPLE_AUTHORIZE_URL);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('response_mode', 'form_post');
  url.searchParams.set('client_id', args.clientId);
  url.searchParams.set('redirect_uri', args.redirectUri);
  url.searchParams.set('scope', args.scope ?? 'name email');
  url.searchParams.set('state', args.state);
  url.searchParams.set('nonce', args.nonce);
  return url.toString();
}

// ---------------------------------------------------------------------------
// ES256 client-secret JWT
// ---------------------------------------------------------------------------

function pemToPkcs8Der(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s+/g, '');
  return base64UrlDecode(body.replace(/\+/g, '-').replace(/\//g, '_'));
}

/**
 * Mint the short-lived ES256 JWT Apple accepts as the OAuth `client_secret`.
 *
 * Generated at runtime from the private key (never stored, never logged),
 * `exp` capped to a few minutes. Apple caps client-secret lifetime at 6 months;
 * a per-request few-minute token means a leak of one exchange can't be replayed.
 */
export async function mintClientSecret(
  config: Pick<AppleWebConfig, 'teamId' | 'keyId' | 'clientId' | 'privateKeyPem'>,
  now: number = Math.floor(Date.now() / 1000),
  ttlSeconds = 300,
): Promise<string> {
  const header = { alg: 'ES256', kid: config.keyId, typ: 'JWT' };
  const payload = {
    iss: config.teamId,
    iat: now,
    exp: now + ttlSeconds,
    aud: APPLE_ISSUER,
    sub: config.clientId,
  };
  const signingInput = `${encodeJson(header)}.${encodeJson(payload)}`;

  const key = await globalThis.crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8Der(config.privateKeyPem),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const sig = await globalThis.crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signingInput),
  );
  // WebCrypto ECDSA already returns the raw r||s concatenation JOSE expects.
  return `${signingInput}.${base64UrlEncode(new Uint8Array(sig))}`;
}

// ---------------------------------------------------------------------------
// Token exchange
// ---------------------------------------------------------------------------

export class AppleAuthError extends Error {
  readonly reason: AppleAuthFailure;
  constructor(reason: AppleAuthFailure, message?: string) {
    super(message ?? reason);
    this.name = 'AppleAuthError';
    this.reason = reason;
  }
}

export type AppleAuthFailure =
  | 'not_configured'
  | 'state_mismatch'
  | 'missing_code'
  | 'token_exchange'
  | 'missing_id_token'
  | 'malformed_token'
  | 'signature'
  | 'unknown_key'
  | 'wrong_issuer'
  | 'wrong_audience'
  | 'expired'
  | 'nonce_mismatch'
  | 'missing_subject';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/**
 * Exchange the one-time authorization `code` for tokens at Apple's token
 * endpoint, authenticating with the freshly minted ES256 client secret.
 * Returns the raw `id_token`. Any non-200 or missing id_token fails closed.
 */
export async function exchangeAppleCode(args: {
  code: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  fetchImpl?: FetchLike;
}): Promise<string> {
  const fetchImpl = args.fetchImpl ?? (globalThis.fetch as FetchLike);
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code: args.code,
    redirect_uri: args.redirectUri,
    client_id: args.clientId,
    client_secret: args.clientSecret,
  });

  let res: Response;
  try {
    res = await fetchImpl(APPLE_TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: body.toString(),
    });
  } catch {
    // Network/TLS failure carries the host in its message — the diagnosable
    // fact is only that the exchange could not complete.
    throw new AppleAuthError('token_exchange');
  }
  if (!res.ok) throw new AppleAuthError('token_exchange');

  let parsed: { id_token?: string };
  try {
    parsed = (await res.json()) as { id_token?: string };
  } catch {
    throw new AppleAuthError('token_exchange');
  }
  if (!parsed.id_token) throw new AppleAuthError('missing_id_token');
  return parsed.id_token;
}

// ---------------------------------------------------------------------------
// Identity-token verification (RS256 against Apple JWKS)
// ---------------------------------------------------------------------------

type AppleJwk = JsonWebKey & { kid?: string; alg?: string; use?: string };
export type AppleJwks = { keys: AppleJwk[] };
export type JwksFetcher = () => Promise<AppleJwks>;

export function defaultJwksFetcher(fetchImpl: FetchLike = globalThis.fetch as FetchLike): JwksFetcher {
  return async () => {
    let res: Response;
    try {
      res = await fetchImpl(APPLE_JWKS_URL, { headers: { Accept: 'application/json' } });
    } catch {
      throw new AppleAuthError('unknown_key');
    }
    if (!res.ok) throw new AppleAuthError('unknown_key');
    try {
      return (await res.json()) as AppleJwks;
    } catch {
      throw new AppleAuthError('unknown_key');
    }
  };
}

export type AppleIdentity = {
  sub: string;
  email?: string;
  emailVerified: boolean;
};

function coerceAppleEmailVerified(value: unknown): boolean {
  // Apple encodes email_verified as the string "true"/"false"; anything that is
  // not an affirmative true reads as UNVERIFIED (fail closed), so it can never
  // be the thing that merges two accounts downstream.
  if (typeof value === 'boolean') return value;
  if (typeof value === 'string') return value.trim().toLowerCase() === 'true';
  return false;
}

/**
 * Fully verify an Apple identity token for the web boundary.
 *
 * Checks, in order and all fail-closed: RS256 header, key resolution against
 * Apple's JWKS, signature, issuer (`appleid.apple.com`), audience (the Tono
 * Services ID), expiry, and the nonce bound to this browser's transaction
 * cookie. Only after all pass is the stable `sub` returned.
 */
export async function verifyAppleIdToken(
  idToken: string,
  opts: {
    clientId: string;
    nonce: string;
    fetchJwks?: JwksFetcher;
    now?: number;
    leewaySeconds?: number;
  },
): Promise<AppleIdentity> {
  const parts = idToken.split('.');
  if (parts.length !== 3) throw new AppleAuthError('malformed_token');
  const [h, p, s] = parts;

  let header: { alg?: string; kid?: string };
  let claims: Record<string, unknown>;
  try {
    header = decodeJsonSegment<{ alg?: string; kid?: string }>(h);
    claims = decodeJsonSegment<Record<string, unknown>>(p);
  } catch {
    throw new AppleAuthError('malformed_token');
  }

  if (header.alg !== 'RS256' || !header.kid) throw new AppleAuthError('malformed_token');

  const jwks = await (opts.fetchJwks ?? defaultJwksFetcher())();
  const jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new AppleAuthError('unknown_key');

  let ok = false;
  try {
    const key = await globalThis.crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    ok = await globalThis.crypto.subtle.verify(
      { name: 'RSASSA-PKCS1-v1_5' },
      key,
      base64UrlDecode(s),
      new TextEncoder().encode(`${h}.${p}`),
    );
  } catch {
    throw new AppleAuthError('signature');
  }
  if (!ok) throw new AppleAuthError('signature');

  if (claims.iss !== APPLE_ISSUER) throw new AppleAuthError('wrong_issuer');

  // Apple's `aud` for a Services ID is a single string. Reject anything that is
  // not exactly the Tono Services ID this boundary owns.
  if (claims.aud !== opts.clientId) throw new AppleAuthError('wrong_audience');

  const now = opts.now ?? Math.floor(Date.now() / 1000);
  const leeway = opts.leewaySeconds ?? 60;
  const exp = typeof claims.exp === 'number' ? claims.exp : 0;
  if (!exp || now > exp + leeway) throw new AppleAuthError('expired');

  // Nonce binds this token to the exact authorize request this browser started.
  // Apple echoes the `nonce` param verbatim in the web flow. A missing or
  // mismatched nonce is a replay/mixup and is refused.
  if (!opts.nonce || claims.nonce !== opts.nonce) throw new AppleAuthError('nonce_mismatch');

  const sub = typeof claims.sub === 'string' ? claims.sub : '';
  if (!sub) throw new AppleAuthError('missing_subject');

  return {
    sub,
    email: typeof claims.email === 'string' ? claims.email : undefined,
    emailVerified: coerceAppleEmailVerified(claims.email_verified),
  };
}
