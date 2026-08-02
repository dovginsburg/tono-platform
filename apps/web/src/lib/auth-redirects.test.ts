import assert from 'node:assert/strict';
import test from 'node:test';

import {
  APP_ENTRY_PATH,
  buildAppRedirect,
  buildAuthCallbackUrl,
  buildLoginRedirect,
  resolvePublicOrigin,
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

// A preview deployment must never silently adopt its own *.vercel.app host for
// URLs that leave the browser. Those hosts sit behind Vercel deployment
// protection and still run this app's auth middleware, so a Stripe receipt or a
// magic-link email built from one strands the recipient on a preview auth wall.
const previewEnv = {
  NODE_ENV: 'production',
  VERCEL_ENV: 'preview',
  VERCEL_URL: 'tono-web-git-candidate-abc123.vercel.app',
};

test('an unconfigured preview deployment resolves to canonical tonoit.com', () => {
  assert.equal(resolvePublicOrigin(undefined, previewEnv), 'https://tonoit.com');
});

test('externally shareable trial, pricing and account URLs never carry a preview host', () => {
  const origin = resolvePublicOrigin(undefined, previewEnv);

  // The exact URLs handed to Stripe (/api/checkout success + cancel) and to the
  // billing portal (/api/portal return_url).
  for (const path of ['/app/welcome-pro?s=1', '/app/pricing', '/app/account']) {
    const url = new URL(`${origin}${path}`);
    assert.equal(url.origin, 'https://tonoit.com', path);
    assert.equal(url.hostname.endsWith('.vercel.app'), false, path);
  }
});

test('preview auth redirects and mailed callbacks stay on the canonical origin', () => {
  for (const built of [
    buildLoginRedirect(APP_ENTRY_PATH, previewEnv),
    buildAppRedirect('/app/pricing', previewEnv),
    buildAuthCallbackUrl(undefined, previewEnv),
  ]) {
    assert.equal(new URL(built).origin, 'https://tonoit.com', built);
  }
});

test('a preview host offered as a candidate origin cannot override the canonical one', () => {
  // login/page.tsx passes window.location.origin as the candidate. On a preview
  // deployment that is the preview host; it must not win.
  assert.equal(
    buildAuthCallbackUrl('https://tono-web-git-candidate-abc123.vercel.app', {
      NODE_ENV: 'production',
      NEXT_PUBLIC_SITE_URL: 'https://tonoit.com',
    }),
    'https://tonoit.com/app/auth/callback'
  );
});

test('a caller-supplied preview host is refused even when it matches VERCEL_URL', () => {
  // The mailed magic link is the most widely shared URL the app emits. A
  // candidate origin must never be able to point it at the preview host, even
  // when that host is this very deployment.
  assert.equal(
    buildAuthCallbackUrl('https://tono-web-git-candidate-abc123.vercel.app', previewEnv),
    'https://tonoit.com/app/auth/callback'
  );
});

test('a candidate origin still wins for local development', () => {
  // Ordering guard: the caller-supplied origin is checked before the configured
  // one, so `next dev` keeps its own localhost callback.
  assert.equal(
    buildAuthCallbackUrl('http://localhost:3000', {
      NODE_ENV: 'development',
      NEXT_PUBLIC_SITE_URL: 'https://tonoit.com',
    }),
    'http://localhost:3000/app/auth/callback'
  );
});

test('an explicitly approved preview origin is still honoured for staging QA', () => {
  // docs/operations/web-protected-redirect-staging.md step 4 — an operator sets
  // NEXT_PUBLIC_SITE_URL to the approved preview origin on purpose. That opt-in
  // survives; only the implicit VERCEL_URL fall-back is gone.
  assert.equal(
    resolvePublicOrigin(undefined, {
      ...previewEnv,
      NEXT_PUBLIC_SITE_URL: 'https://tono-web-git-candidate-abc123.vercel.app',
    }),
    'https://tono-web-git-candidate-abc123.vercel.app'
  );
});
