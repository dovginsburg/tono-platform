import assert from 'node:assert/strict';
import test from 'node:test';

import {
  APP_ENTRY_PATH,
  buildAppRedirect,
  buildAuthCallbackUrl,
  buildLoginRedirect,
  sanitizeNextPath,
} from './auth-redirects.ts';

const productionEnv = {
  NODE_ENV: 'production',
  NEXT_PUBLIC_SITE_URL: 'https://tonoit.com',
};

test('direct protected-app navigation redirects to the existing basePath login URL', () => {
  const redirect = new URL(buildLoginRedirect(APP_ENTRY_PATH, productionEnv));

  assert.equal(redirect.origin, 'https://tonoit.com');
  assert.equal(redirect.pathname, '/app/login');
  assert.equal(redirect.searchParams.get('next'), '/app/app');
  assert.equal(redirect.pathname.includes('/app/app/login'), false);
});

test('validated app return paths survive login and callback redirects', () => {
  const next = '/app/app/history?filter=recent';

  assert.equal(sanitizeNextPath(next), next);
  assert.equal(buildAppRedirect(next, productionEnv), `https://tonoit.com${next}`);
});

test('the whole /app surface is a valid post-login destination, not just the editor', () => {
  // Conversion depends on returning a signed-out visitor to where they were
  // headed — /app/pricing (finish checkout), /app/account (manage billing).
  for (const p of ['/app/pricing', '/app/account', '/app/pricing?interval=year']) {
    assert.equal(sanitizeNextPath(p), p, p);
  }
});

test('next never loops back into an auth route', () => {
  // A next that points at login/callback would bounce the visitor straight
  // back into the sign-in flow — fall back to the editor entry instead.
  for (const p of ['/app/login', '/app/login?next=/app/pricing', '/app/auth/callback']) {
    assert.equal(sanitizeNextPath(p), APP_ENTRY_PATH, p);
  }
});

test('hostile next inputs cannot become cross-origin redirects', () => {
  const hostileInputs = [
    'https://evil.example/steal',
    '//evil.example/steal',
    '/\\evil.example/steal',
    'javascript:alert(1)',
    '%2F%2Fevil.example/steal',
    '/app/login',
    '/app/app/../../outside',
  ];

  for (const input of hostileInputs) {
    const redirect = new URL(buildAppRedirect(input, productionEnv));
    assert.equal(redirect.origin, 'https://tonoit.com', input);
    assert.equal(redirect.pathname, APP_ENTRY_PATH, input);
  }
});

test('hostile public-origin configuration falls back to tonoit.com', () => {
  const redirect = new URL(
    buildLoginRedirect(APP_ENTRY_PATH, {
      NODE_ENV: 'production',
      NEXT_PUBLIC_SITE_URL: 'https://evil.example',
      VERCEL_URL: 'evil.example',
    })
  );

  assert.equal(redirect.origin, 'https://tonoit.com');
});

test('local development stays local when no public origin is configured', () => {
  const redirect = new URL(
    buildLoginRedirect(APP_ENTRY_PATH, { NODE_ENV: 'development' })
  );

  assert.equal(redirect.origin, 'http://localhost:3000');
});

test('callback URL uses the same basePath contract as login and logout', () => {
  assert.equal(
    buildAuthCallbackUrl('https://tonoit.com', productionEnv),
    'https://tonoit.com/app/auth/callback'
  );
});
