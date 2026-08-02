import assert from 'node:assert/strict';
import test from 'node:test';

import {
  readAppleWebConfig,
  appleWebBoundaryConfigured,
  base64UrlEncode,
  base64UrlDecode,
  randomToken,
  buildAppleAuthorizeUrl,
  mintClientSecret,
  exchangeAppleCode,
  verifyAppleIdToken,
  AppleAuthError,
  defaultJwksFetcher,
  APPLE_ISSUER,
  DEFAULT_APPLE_WEB_REDIRECT_URI,
  type AppleWebEnv,
  type AppleJwks,
} from './apple-web-auth.ts';

const enc = (s: string) => new TextEncoder().encode(s);

// ---------------------------------------------------------------------------
// Test key material — generated per run, never a real secret.
// ---------------------------------------------------------------------------

function toPem(der: ArrayBuffer, label: string): string {
  const bytes = new Uint8Array(der);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  const b64 = btoa(bin);
  const lines = b64.match(/.{1,64}/g)!.join('\n');
  return `-----BEGIN ${label}-----\n${lines}\n-----END ${label}-----\n`;
}

async function makeEs256Key() {
  const pair = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' },
    true,
    ['sign', 'verify'],
  );
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', pair.privateKey);
  return { publicKey: pair.publicKey, privateKeyPem: toPem(pkcs8, 'PRIVATE KEY') };
}

const RS_KID = 'test-apple-key-1';

async function makeRs256Key() {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const jwk = (await crypto.subtle.exportKey('jwk', pair.publicKey)) as JsonWebKey & { kid?: string };
  jwk.kid = RS_KID;
  return { privateKey: pair.privateKey, jwk };
}

async function signIdToken(
  privateKey: CryptoKey,
  claims: Record<string, unknown>,
  overrides: { alg?: string; kid?: string; tamper?: boolean } = {},
): Promise<string> {
  const header = { alg: overrides.alg ?? 'RS256', kid: overrides.kid ?? RS_KID, typ: 'JWT' };
  const h = base64UrlEncode(enc(JSON.stringify(header)));
  const p = base64UrlEncode(enc(JSON.stringify(claims)));
  const sig = await crypto.subtle.sign({ name: 'RSASSA-PKCS1-v1_5' }, privateKey, enc(`${h}.${p}`));
  let s = base64UrlEncode(new Uint8Array(sig));
  if (overrides.tamper) s = s.slice(0, -3) + (s.endsWith('AAA') ? 'BBB' : 'AAA');
  return `${h}.${p}.${s}`;
}

const CLIENT_ID = 'tonoit.com';
const NOW = 1_800_000_000; // fixed clock

function baseClaims(nonce: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: APPLE_ISSUER,
    aud: CLIENT_ID,
    sub: 'apple-sub-000123',
    iat: NOW - 30,
    exp: NOW + 3600,
    nonce,
    email: 'person@example.com',
    email_verified: 'true',
    ...extra,
  };
}

// ---------------------------------------------------------------------------
// Config — fail closed
// ---------------------------------------------------------------------------

const FULL_ENV: AppleWebEnv = {
  APPLE_WEB_TEAM_ID: '4938S9TTBM',
  APPLE_WEB_KEY_ID: '5H8DJ2K7DU',
  APPLE_WEB_CLIENT_ID: 'tonoit.com',
  APPLE_WEB_PRIVATE_KEY: '-----BEGIN PRIVATE KEY-----\nMIG\n-----END PRIVATE KEY-----',
  APPLE_WEB_REDIRECT_URI: 'https://tonoit.com/api/auth/apple/callback',
};

test('config fails closed when any required env is absent', () => {
  assert.equal(readAppleWebConfig({}), null);
  assert.equal(appleWebBoundaryConfigured({}), false);
  for (const key of ['APPLE_WEB_TEAM_ID', 'APPLE_WEB_KEY_ID', 'APPLE_WEB_CLIENT_ID', 'APPLE_WEB_PRIVATE_KEY']) {
    const partial = { ...FULL_ENV };
    delete (partial as Record<string, unknown>)[key];
    assert.equal(readAppleWebConfig(partial), null, `missing ${key} must fail closed`);
  }
});

test('config rejects the contaminated sibling Services ID even if pasted into server env', () => {
  assert.equal(readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_CLIENT_ID: 'parentscript.app' }), null);
});

test('config rejects a foreign (non-Tono) Services ID', () => {
  assert.equal(readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_CLIENT_ID: 'com.example.web' }), null);
});

test('config honours an operator-pinned expected client id (strict equality)', () => {
  assert.equal(
    readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_EXPECTED_CLIENT_ID: 'not.the.configured.one' }),
    null,
  );
  assert.ok(readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_EXPECTED_CLIENT_ID: 'tonoit.com' }));
});

test('config rejects a non-https redirect URI', () => {
  assert.equal(readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_REDIRECT_URI: 'http://tonoit.com/x' }), null);
  assert.equal(readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_REDIRECT_URI: 'not-a-url' }), null);
});

test('config accepts a complete, Tono-owned configuration', () => {
  const config = readAppleWebConfig(FULL_ENV);
  assert.ok(config);
  assert.equal(config!.teamId, '4938S9TTBM');
  assert.equal(config!.keyId, '5H8DJ2K7DU');
  assert.equal(config!.clientId, 'tonoit.com');
  assert.equal(config!.redirectUri, 'https://tonoit.com/api/auth/apple/callback');
});

test('config defaults the redirect URI when unset', () => {
  const config = readAppleWebConfig({ ...FULL_ENV, APPLE_WEB_REDIRECT_URI: undefined });
  assert.equal(config!.redirectUri, DEFAULT_APPLE_WEB_REDIRECT_URI);
});

// ---------------------------------------------------------------------------
// base64url + random
// ---------------------------------------------------------------------------

test('base64url round-trips arbitrary bytes without padding', () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255]);
  const encoded = base64UrlEncode(bytes);
  assert.doesNotMatch(encoded, /[+/=]/);
  assert.deepEqual(base64UrlDecode(encoded), bytes);
});

test('randomToken returns strong, distinct, URL-safe tokens', () => {
  const a = randomToken();
  const b = randomToken();
  assert.notEqual(a, b);
  assert.doesNotMatch(a, /[+/=]/);
  assert.ok(a.length >= 43); // 32 bytes → 43 base64url chars
});

// ---------------------------------------------------------------------------
// Authorize URL
// ---------------------------------------------------------------------------

test('authorize URL carries client_id, redirect, state, nonce and form_post', () => {
  const url = new URL(
    buildAppleAuthorizeUrl({
      clientId: 'tonoit.com',
      redirectUri: 'https://tonoit.com/api/auth/apple/callback',
      state: 'st-123',
      nonce: 'no-456',
    }),
  );
  assert.equal(url.origin + url.pathname, 'https://appleid.apple.com/auth/authorize');
  assert.equal(url.searchParams.get('client_id'), 'tonoit.com');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://tonoit.com/api/auth/apple/callback');
  assert.equal(url.searchParams.get('response_type'), 'code');
  assert.equal(url.searchParams.get('response_mode'), 'form_post');
  assert.equal(url.searchParams.get('state'), 'st-123');
  assert.equal(url.searchParams.get('nonce'), 'no-456');
  assert.match(url.searchParams.get('scope') ?? '', /email/);
  // Never the sibling product's id.
  assert.doesNotMatch(url.toString(), /parentscript/);
});

// ---------------------------------------------------------------------------
// ES256 client secret
// ---------------------------------------------------------------------------

test('client secret is a valid ES256 JWT with the Apple-required claims', async () => {
  const { publicKey, privateKeyPem } = await makeEs256Key();
  const secret = await mintClientSecret(
    { teamId: '4938S9TTBM', keyId: '5H8DJ2K7DU', clientId: 'tonoit.com', privateKeyPem },
    NOW,
  );
  const [h, p, s] = secret.split('.');
  const header = JSON.parse(new TextDecoder().decode(base64UrlDecode(h)));
  const payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(p)));
  assert.equal(header.alg, 'ES256');
  assert.equal(header.kid, '5H8DJ2K7DU');
  assert.equal(payload.iss, '4938S9TTBM');
  assert.equal(payload.sub, 'tonoit.com');
  assert.equal(payload.aud, APPLE_ISSUER);
  assert.equal(payload.iat, NOW);
  assert.equal(payload.exp, NOW + 300);

  // The signature verifies under the matching public key.
  const ok = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    publicKey,
    base64UrlDecode(s),
    enc(`${h}.${p}`),
  );
  assert.equal(ok, true);
});

// ---------------------------------------------------------------------------
// Token exchange
// ---------------------------------------------------------------------------

test('exchangeAppleCode returns the id_token on success', async () => {
  const id = await exchangeAppleCode({
    code: 'c',
    clientId: 'tonoit.com',
    clientSecret: 'secret',
    redirectUri: 'https://tonoit.com/api/auth/apple/callback',
    fetchImpl: async () => new Response(JSON.stringify({ id_token: 'ID.TOK.EN' }), { status: 200 }),
  });
  assert.equal(id, 'ID.TOK.EN');
});

test('exchangeAppleCode fails closed on a non-200 from Apple', async () => {
  await assert.rejects(
    exchangeAppleCode({
      code: 'c', clientId: 'tonoit.com', clientSecret: 's', redirectUri: 'https://x/y',
      fetchImpl: async () => new Response('{"error":"invalid_grant"}', { status: 400 }),
    }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'token_exchange',
  );
});

test('exchangeAppleCode fails closed when Apple returns no id_token', async () => {
  await assert.rejects(
    exchangeAppleCode({
      code: 'c', clientId: 'tonoit.com', clientSecret: 's', redirectUri: 'https://x/y',
      fetchImpl: async () => new Response(JSON.stringify({ access_token: 'a' }), { status: 200 }),
    }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'missing_id_token',
  );
});

test('exchangeAppleCode fails closed on a network error', async () => {
  await assert.rejects(
    exchangeAppleCode({
      code: 'c', clientId: 'tonoit.com', clientSecret: 's', redirectUri: 'https://x/y',
      fetchImpl: async () => { throw new Error('ECONNRESET api host leaked here'); },
    }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'token_exchange',
  );
});

// ---------------------------------------------------------------------------
// Identity-token verification
// ---------------------------------------------------------------------------

async function verifyWith(
  token: string,
  jwk: JsonWebKey,
  opts: { nonce: string; clientId?: string; now?: number },
) {
  const jwks: AppleJwks = { keys: [jwk as AppleJwks['keys'][number]] };
  return verifyAppleIdToken(token, {
    clientId: opts.clientId ?? CLIENT_ID,
    nonce: opts.nonce,
    now: opts.now ?? NOW,
    fetchJwks: async () => jwks,
  });
}

test('verifyAppleIdToken accepts a well-formed token and returns the verified identity', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('nonce-abc'));
  const identity = await verifyWith(token, jwk, { nonce: 'nonce-abc' });
  assert.equal(identity.sub, 'apple-sub-000123');
  assert.equal(identity.email, 'person@example.com');
  assert.equal(identity.emailVerified, true);
});

test('verifyAppleIdToken treats a non-affirmative email_verified as unverified', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n', { email_verified: 'false' }));
  const identity = await verifyWith(token, jwk, { nonce: 'n' });
  assert.equal(identity.emailVerified, false);
});

test('verifyAppleIdToken rejects a malformed token', async () => {
  const { jwk } = await makeRs256Key();
  await assert.rejects(
    verifyWith('not.a.jwt.at.all', jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'malformed_token',
  );
});

test('verifyAppleIdToken rejects a non-RS256 alg header (no algorithm confusion)', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n'), { alg: 'ES256' });
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'malformed_token',
  );
});

test('verifyAppleIdToken rejects an unknown signing key (kid not in JWKS)', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n'), { kid: 'some-other-kid' });
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'unknown_key',
  );
});

test('verifyAppleIdToken rejects a bad signature', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n'), { tamper: true });
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'signature',
  );
});

test('verifyAppleIdToken rejects a token signed by a DIFFERENT key', async () => {
  const attacker = await makeRs256Key();
  const legit = await makeRs256Key(); // its public JWK is the one we trust
  const token = await signIdToken(attacker.privateKey, baseClaims('n'));
  await assert.rejects(
    verifyWith(token, legit.jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'signature',
  );
});

test('verifyAppleIdToken rejects the wrong issuer', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n', { iss: 'https://evil.example.com' }));
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'wrong_issuer',
  );
});

test('verifyAppleIdToken rejects the wrong audience (sibling Services ID)', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n', { aud: 'parentscript.app' }));
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'wrong_audience',
  );
});

test('verifyAppleIdToken rejects an expired token', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('n', { exp: NOW - 3600 }));
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'expired',
  );
});

test('verifyAppleIdToken rejects a nonce mismatch (replay/mixup)', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const token = await signIdToken(privateKey, baseClaims('the-real-nonce'));
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'a-different-nonce' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'nonce_mismatch',
  );
});

test('verifyAppleIdToken rejects a token missing the subject', async () => {
  const { privateKey, jwk } = await makeRs256Key();
  const claims = baseClaims('n');
  delete (claims as Record<string, unknown>).sub;
  const token = await signIdToken(privateKey, claims);
  await assert.rejects(
    verifyWith(token, jwk, { nonce: 'n' }),
    (e: unknown) => e instanceof AppleAuthError && e.reason === 'missing_subject',
  );
});

test('defaultJwksFetcher fails closed on a JWKS fetch error', async () => {
  const fetcher = defaultJwksFetcher(async () => { throw new Error('dns'); });
  await assert.rejects(fetcher(), (e: unknown) => e instanceof AppleAuthError && e.reason === 'unknown_key');
});
