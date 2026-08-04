import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  APP_ENTRY_PATH,
  AUTH_RESET_PATH,
  LOGIN_PATH,
} from './auth-redirects.ts';
import {
  classifyFragmentError,
  classifySetSessionFailure,
  isRecoveryCompletion,
  loginPathWithError,
  resolveCompleteRedirect,
  FRAGMENT_BOUNCE_HTML,
} from './auth-complete.ts';

test('classifyFragmentError maps GoTrue implicit error codes to reviewed codes', () => {
  // Expired / spent / denied links are the common failure and keep their own step.
  assert.equal(classifyFragmentError('access_denied', 'otp_expired'), 'link_expired');
  assert.equal(classifyFragmentError(null, 'otp_expired'), 'link_expired');
  assert.equal(classifyFragmentError('access_denied', null), 'link_expired');
  // Throttling stays distinct from a credential/failure.
  assert.equal(classifyFragmentError(null, 'over_email_send_rate_limit'), 'rate_limited');
  // Provider infra failure.
  assert.equal(classifyFragmentError(null, 'unexpected_failure'), 'unavailable');
  // Anything unrecognised (and the empty case) is a generic sign-in failure.
  assert.equal(classifyFragmentError('server_error', null), 'unavailable');
  assert.equal(classifyFragmentError(null, null), 'sign_in_failed');
  assert.equal(classifyFragmentError('', ''), 'sign_in_failed');
});

test('classifySetSessionFailure maps status to reviewed codes', () => {
  assert.equal(classifySetSessionFailure(429), 'rate_limited');
  assert.equal(classifySetSessionFailure(401), 'link_expired');
  assert.equal(classifySetSessionFailure(403), 'link_expired');
  assert.equal(classifySetSessionFailure(410), 'link_expired');
  assert.equal(classifySetSessionFailure(500), 'unavailable');
  assert.equal(classifySetSessionFailure(503), 'unavailable');
  assert.equal(classifySetSessionFailure(400), 'sign_in_failed');
  assert.equal(classifySetSessionFailure(null), 'sign_in_failed');
  assert.equal(classifySetSessionFailure(undefined), 'sign_in_failed');
});

test('isRecoveryCompletion recognises both the provider and our markers', () => {
  assert.equal(isRecoveryCompletion('recovery', null), true); // GoTrue fragment type
  assert.equal(isRecoveryCompletion(null, 'recovery'), true); // our ?flow=recovery
  assert.equal(isRecoveryCompletion('signup', null), false);
  assert.equal(isRecoveryCompletion(null, null), false);
  assert.equal(isRecoveryCompletion('', ''), false);
});

test('loginPathWithError carries a reviewed code and a sanitized next', () => {
  const p = loginPathWithError('link_expired');
  const url = new URL(p, 'https://tonoit.com');
  assert.equal(url.pathname, LOGIN_PATH);
  assert.equal(url.searchParams.get('error'), 'link_expired');
  // Absent next defaults to the editor entry; it is never left blank.
  assert.equal(url.searchParams.get('next'), APP_ENTRY_PATH);
  // A hostile next can never survive into an open redirect.
  const evil = new URL(loginPathWithError('rate_limited', 'https://evil.com/'), 'https://tonoit.com');
  assert.equal(evil.searchParams.get('next'), APP_ENTRY_PATH);
});

test('resolveCompleteRedirect: a failed link goes to login with the mapped code', () => {
  const p = resolveCompleteRedirect({
    fragmentError: 'access_denied',
    fragmentErrorCode: 'otp_expired',
    hasTokens: false,
    sessionEstablished: false,
    recovery: true,
  });
  const url = new URL(p, 'https://tonoit.com');
  assert.equal(url.pathname, LOGIN_PATH);
  assert.equal(url.searchParams.get('error'), 'link_expired');
});

test('resolveCompleteRedirect: no tokens and no error quietly returns to login', () => {
  assert.equal(
    resolveCompleteRedirect({ hasTokens: false, sessionEstablished: false, recovery: false }),
    LOGIN_PATH,
  );
});

test('resolveCompleteRedirect: tokens present but setSession refused -> login w/ status code', () => {
  const p = resolveCompleteRedirect({
    hasTokens: true,
    sessionEstablished: false,
    sessionFailureStatus: 401,
    recovery: false,
  });
  const url = new URL(p, 'https://tonoit.com');
  assert.equal(url.pathname, LOGIN_PATH);
  assert.equal(url.searchParams.get('error'), 'link_expired');
});

test('resolveCompleteRedirect: recovery success lands on the password screen', () => {
  assert.equal(
    resolveCompleteRedirect({ hasTokens: true, sessionEstablished: true, recovery: true }),
    AUTH_RESET_PATH,
  );
});

test('resolveCompleteRedirect: confirmation success lands in the app (default or sanitized next)', () => {
  assert.equal(
    resolveCompleteRedirect({ hasTokens: true, sessionEstablished: true, recovery: false }),
    APP_ENTRY_PATH,
  );
  assert.equal(
    resolveCompleteRedirect({ hasTokens: true, sessionEstablished: true, recovery: false, next: '/app/pricing' }),
    '/app/pricing',
  );
  // An auth route as `next` must not loop the flow — falls back to the editor.
  assert.equal(
    resolveCompleteRedirect({ hasTokens: true, sessionEstablished: true, recovery: false, next: LOGIN_PATH }),
    APP_ENTRY_PATH,
  );
});

test('FRAGMENT_BOUNCE_HTML posts to the completion route and never renders provider text', () => {
  // Posts the fragment to the one server half.
  assert.match(FRAGMENT_BOUNCE_HTML, /\/app\/api\/auth\/email\/complete/);
  // Reads the fragment (client-only) and follows the server's single redirect.
  assert.match(FRAGMENT_BOUNCE_HTML, /location\.hash/);
  assert.match(FRAGMENT_BOUNCE_HTML, /location\.replace/);
  assert.match(FRAGMENT_BOUNCE_HTML, /access_token/);
  // Not indexed, and it has a no-JS way forward.
  assert.match(FRAGMENT_BOUNCE_HTML, /noindex/);
  assert.match(FRAGMENT_BOUNCE_HTML, /<noscript>/);
  // It forwards only the stable machine error, never the free-form description.
  assert.doesNotMatch(FRAGMENT_BOUNCE_HTML, /error_description/);
});
