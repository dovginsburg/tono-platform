import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  EMAIL_AUTH_COPY,
  EMAIL_AUTH_OUTCOMES,
  MIN_PASSWORD_LENGTH,
  classifyBackendStatus,
  classifyProviderFailure,
  looksLikeEmail,
  resolvePasswordUpdate,
  sanitizeEmailAuthOutcome,
  validateNewPassword,
} from './email-auth.ts';
import { isRecoveryCallback, buildResetRedirect, AUTH_RESET_PATH } from './auth-redirects.ts';

const here = dirname(fileURLToPath(import.meta.url));
const srcRoot = join(here, '..');
const productionEnv = { NODE_ENV: 'production', NEXT_PUBLIC_SITE_URL: 'https://tonoit.com' };

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (p.endsWith('.ts') || p.endsWith('.tsx')) out.push(p);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Anti-enumeration
// ---------------------------------------------------------------------------

test('asking for mail answers identically for a known and an unknown address', () => {
  // 202 is what the backend returns for register/resend/reset whether or not
  // the address exists. If this surface ever classified those differently, the
  // page would answer the one question an attacker has.
  for (const status of [200, 202]) {
    assert.equal(classifyBackendStatus(status, 'check_your_email'), 'check_your_email');
  }
});

test('a rejected registration never rides the check-your-inbox path', () => {
  // Telling someone to watch their inbox when the provider refused the request
  // is the one failure they can never recover from on their own.
  assert.equal(classifyBackendStatus(400, 'check_your_email'), 'invalid_input');
  assert.equal(classifyBackendStatus(429, 'check_your_email'), 'rate_limited');
  assert.equal(classifyBackendStatus(503, 'check_your_email'), 'unavailable');
});

// ---------------------------------------------------------------------------
// No provider / transport / status jargon reaches a person
// ---------------------------------------------------------------------------

test('every outcome has copy, and the copy set is exactly the outcome set', () => {
  assert.deepEqual(Object.keys(EMAIL_AUTH_COPY).sort(), [...EMAIL_AUTH_OUTCOMES].sort());
});

test('no consumer sentence contains backend, provider or transport vocabulary', () => {
  // The banned words are the ones that describe OUR implementation rather than
  // the person's situation. A sentence carrying any of them has stopped being
  // consumer copy.
  const banned = [
    'supabase', 'http', 'api', 'token', 'endpoint', 'backend', 'server',
    'status', '4xx', '5xx', 'null', 'undefined', 'jwt', 'oauth', 'provider',
    'exception', 'error code', 'request failed', 'bearer',
  ];
  for (const [code, sentence] of Object.entries(EMAIL_AUTH_COPY)) {
    const lower = sentence.toLowerCase();
    for (const word of banned) {
      assert.ok(!lower.includes(word), `${code} copy contains "${word}": ${sentence}`);
    }
    assert.ok(!/\b[45]\d{2}\b/.test(sentence), `${code} copy contains a status code: ${sentence}`);
  }
});

test('every failure sentence offers a next step', () => {
  // A failure with no action is the shape this build is fixing. Each of these
  // has to end somewhere the person can go.
  const failures = ['invalid_credentials', 'verification_required', 'invalid_input',
    'password_mismatch', 'link_expired', 'account_conflict', 'rate_limited',
    'unavailable', 'offline', 'unknown_failure'] as const;
  for (const code of failures) {
    const sentence = EMAIL_AUTH_COPY[code].toLowerCase();
    assert.ok(
      /try|open|request|wait|check|type|sign in|use another|different/.test(sentence),
      `${code} copy leaves the person with nothing to do: ${sentence}`
    );
  }
});

test('an unrecognised outcome is dropped rather than rendered', () => {
  assert.equal(sanitizeEmailAuthOutcome('Invalid login credentials'), null);
  assert.equal(sanitizeEmailAuthOutcome('<script>'), null);
  assert.equal(sanitizeEmailAuthOutcome(null), null);
  assert.equal(sanitizeEmailAuthOutcome('rate_limited'), 'rate_limited');
});

test('no email-account surface renders a provider or server message directly', () => {
  // Structural guard, not a copy check: if a component reads `.message` off a
  // caught failure and puts it in state, provider text is one render away.
  const offenders: string[] = [];
  for (const file of [
    join(srcRoot, 'app', 'login', 'page.tsx'),
    join(srcRoot, 'app', 'auth', 'reset', 'reset-client.tsx'),
    join(srcRoot, 'app', 'auth', 'reset', 'page.tsx'),
  ]) {
    const src = readFileSync(file, 'utf8');
    for (const re of [/\berr(?:or)?\.message\b/, /\bdata\.(?:message|detail|error_description)\b/]) {
      if (re.test(src)) offenders.push(file.slice(srcRoot.length));
    }
  }
  assert.deepEqual(offenders, [], `renders upstream text: ${offenders.join(', ')}`);
});

// ---------------------------------------------------------------------------
// Password reset can actually complete
// ---------------------------------------------------------------------------

test('a recovery link is recognised from our own marker, not provider formatting', () => {
  assert.equal(isRecoveryCallback(new URLSearchParams('code=abc&flow=recovery')), true);
  // The provider's own marker is honoured too, for a link minted before ours.
  assert.equal(isRecoveryCallback(new URLSearchParams('code=abc&type=recovery')), true);
  // An ordinary sign-in must NOT be diverted to the password screen.
  assert.equal(isRecoveryCallback(new URLSearchParams('code=abc')), false);
  assert.equal(isRecoveryCallback(new URLSearchParams('code=abc&next=/app/pricing')), false);
  assert.equal(isRecoveryCallback(new URLSearchParams('flow=signup')), false);
});

test('the recovery destination is the password screen on the canonical origin', () => {
  const url = new URL(buildResetRedirect(productionEnv));
  assert.equal(url.origin, 'https://tonoit.com');
  assert.equal(url.pathname, AUTH_RESET_PATH);
});

test('the reset screen exists and is reachable', () => {
  // The defect was an advertised affordance with no screen behind it, so the
  // existence of the screen is itself the assertion.
  const page = join(srcRoot, 'app', 'auth', 'reset', 'page.tsx');
  assert.ok(readFileSync(page, 'utf8').length > 0);
  const route = join(srcRoot, 'app', 'api', 'auth', 'password', 'route.ts');
  const src = readFileSync(route, 'utf8');
  assert.match(src, /updateUser\(\s*\{\s*password\s*\}\s*\)/, 'nothing here sets a password');
  assert.match(src, /resolvePasswordUpdate/, 'the route must use the tested decision table');
});

test('finishing a reset resolves every case it can actually hit', () => {
  const good = 'a'.repeat(MIN_PASSWORD_LENGTH);

  // The success this whole flow exists for.
  assert.equal(
    resolvePasswordUpdate({ password: good, confirmation: good, hasSession: true }),
    'password_updated'
  );

  // A typo, caught before the single-use recovery session is spent.
  assert.equal(
    resolvePasswordUpdate({ password: good, confirmation: 'something-else', hasSession: true }),
    'password_mismatch'
  );
  assert.equal(
    resolvePasswordUpdate({ password: 'short', confirmation: 'short', hasSession: true }),
    'invalid_input'
  );

  // The likeliest failure of the whole flow: an expired, spent, or never-followed
  // link. It must NOT collapse into a generic error — its next step is different.
  assert.equal(
    resolvePasswordUpdate({ password: good, confirmation: good, hasSession: false }),
    'link_expired'
  );
  // ...and a local problem is still reported ahead of it, because the person
  // can fix that one without another link.
  assert.equal(
    resolvePasswordUpdate({ password: good, confirmation: 'nope', hasSession: false }),
    'password_mismatch'
  );

  // The provider refused the new password on its own rules.
  assert.equal(
    resolvePasswordUpdate({
      password: good,
      confirmation: good,
      hasSession: true,
      updateError: { status: 422 },
    }),
    'invalid_input'
  );
  assert.equal(
    resolvePasswordUpdate({
      password: good,
      confirmation: good,
      hasSession: true,
      updateError: { status: 503 },
    }),
    'unavailable'
  );

  // Whatever the provider says, the answer is always a reviewed code — so no
  // provider sentence can reach the screen through this path.
  const leaky = { status: 400, message: 'Password should be at least 6 characters. (project abcd)' };
  const outcome = resolvePasswordUpdate({
    password: good,
    confirmation: good,
    hasSession: true,
    updateError: leaky,
  });
  assert.ok(sanitizeEmailAuthOutcome(outcome), 'a raw provider failure escaped the vocabulary');
  assert.ok(!EMAIL_AUTH_COPY[outcome].includes('project abcd'));
});

test('a mismatch is reported before a length complaint', () => {
  // Telling someone their second password is too short answers a question they
  // did not ask.
  assert.equal(validateNewPassword('short', 'different'), 'password_mismatch');
  assert.equal(validateNewPassword('short', 'short'), 'invalid_input');
  assert.equal(validateNewPassword('a'.repeat(MIN_PASSWORD_LENGTH), 'a'.repeat(MIN_PASSWORD_LENGTH)), null);
});

test('a spent or expired recovery session is distinguishable from a generic failure', () => {
  // It has its own next step — ask for another link — so it must not collapse.
  for (const status of [401, 403, 410]) {
    assert.equal(classifyProviderFailure({ status }), 'link_expired');
  }
  assert.equal(classifyProviderFailure({ status: 429 }), 'rate_limited');
  assert.equal(classifyProviderFailure({ status: 500 }), 'unavailable');
  assert.equal(classifyProviderFailure(new Error('boom')), 'unknown_failure');
});

// ---------------------------------------------------------------------------
// The web has the whole lifecycle
// ---------------------------------------------------------------------------

test('every required email flow has a route handler on the web', () => {
  // Registration, password login, resend, reset and the reset completion were
  // all absent; sign-out already existed. Each must resolve to a real handler.
  for (const route of [
    ['api', 'auth', 'email', 'register'],
    ['api', 'auth', 'email', 'login'],
    ['api', 'auth', 'email', 'resend'],
    ['api', 'auth', 'email', 'reset'],
    ['api', 'auth', 'password'],
    ['api', 'auth', 'signout'],
  ]) {
    const file = join(srcRoot, 'app', ...route, 'route.ts');
    assert.ok(readFileSync(file, 'utf8').length > 0, `${route.join('/')} has no handler`);
  }
});

test('the email lifecycle goes through the canonical backend, not straight to the provider', () => {
  // The point of the whole design: one identity system reached from a fourth
  // surface. A browser-side signUp would create a second, unledgered path.
  const routes = walk(join(srcRoot, 'app', 'api', 'auth'));
  const joined = routes.map((f) => readFileSync(f, 'utf8')).join('\n');
  assert.match(joined, /v1\/auth\/email\/register/);
  assert.match(joined, /v1\/auth\/email\/login/);
  assert.match(joined, /v1\/auth\/email\/resend/);
  assert.match(joined, /v1\/auth\/email\/reset/);

  const login = readFileSync(join(srcRoot, 'app', 'login', 'page.tsx'), 'utf8');
  assert.ok(!/signUp\(/.test(login), 'the page registers against the provider directly');
});

test('web email calls are tagged to the web surface and build', () => {
  const helper = readFileSync(join(srcRoot, 'lib', 'email-auth-server.ts'), 'utf8');
  assert.match(helper, /source_surface/);
  assert.match(helper, /WEB_SURFACE = 'web'/);
  assert.match(helper, /WEB_APP_VERSION = 'web-114'/);
});

test('OAuth, passkey and magic link all survive', () => {
  // Adding password auth must not remove a way in that people already use.
  const login = readFileSync(join(srcRoot, 'app', 'login', 'page.tsx'), 'utf8');
  assert.match(login, /signInWithOAuth/);
  assert.match(login, /signInWithOtp/);
  assert.match(login, /PasskeyLoginButton/);
});

// ---------------------------------------------------------------------------
// Input shaping
// ---------------------------------------------------------------------------

test('an obviously unsendable address never becomes a request', () => {
  for (const bad of ['', '   ', 'nope', 'a@b', '@example.com', 'a b@example.com', 'trailing@']) {
    assert.equal(looksLikeEmail(bad), false, bad);
  }
  for (const good of ['a@example.com', 'first.last+tag@sub.example.co.uk']) {
    assert.equal(looksLikeEmail(good), true, good);
  }
});

test('a + tag and a dot survive the shape check', () => {
  // Stripping either is a silent-merge vector, so nothing on this surface may
  // treat them as noise.
  assert.equal(looksLikeEmail('victim+anything@gmail.com'), true);
  assert.equal(looksLikeEmail('first.last@gmail.com'), true);
});
