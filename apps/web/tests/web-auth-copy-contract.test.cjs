// Build 114 — the web sign-in surface: anti-enumerating copy, no raw provider
// text on screen, and no secret in a server log.
//
// These are asserted against the sources that actually ship. The three defects
// they pin were all live before Build 114:
//
//   1. `/auth/callback` forwarded the auth provider's own `error_description`
//      and `error.message` into the /login URL, where the page rendered them.
//      Those messages differ for a known and an unknown address, so the URL was
//      an account-enumeration oracle as well as a provider-detail leak.
//   2. the login page rendered `err.message` from the provider client directly.
//   3. the callback logged the canonical sign-in RESPONSE BODY — which contains
//      `api_token` on success — into the server log.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = (relative) =>
  fs.readFileSync(path.join(__dirname, '..', relative), 'utf8');

const callback = read('src/app/auth/callback/route.ts');
const loginPage = read('src/app/login/page.tsx');
const redirects = read('src/lib/auth-redirects.ts');
// Build 114 remediation — the reviewed sentences moved out of the login page
// into a shared module when the web gained the rest of the email lifecycle
// (register, password sign-in, resend, reset) and the password-reset screen.
// They are asserted here rather than only in that module's own tests, because
// this file is the one that pins the property against the sources that ship.
const emailCopy = read('src/lib/email-auth.ts');

/** Strip comments so prose explaining a ban cannot fail that ban. */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//') && !line.trim().startsWith('*'))
    .join('\n');
}

test('the sign-in failure vocabulary is a closed set of codes', () => {
  assert.match(redirects, /export const AUTH_ERROR_CODES = \[/);
  for (const code of ['sign_in_failed', 'link_expired', 'rate_limited', 'unavailable']) {
    assert.ok(redirects.includes(`'${code}'`), `${code} must be a reviewed code`);
  }
  // An unreviewed value must be dropped, not displayed.
  assert.match(redirects, /export function sanitizeAuthErrorCode/);
  assert.match(
    stripComments(redirects),
    /const code = sanitizeAuthErrorCode\(error\);\s*\n\s*if \(code\) login\.searchParams\.set\('error', code\)/,
    'buildLoginRedirect must only ever set a sanitized code'
  );
});

test('the callback never forwards provider text into the login URL', () => {
  const code = stripComments(callback);
  // Reading the query param is fine; FORWARDING it is the defect.
  for (const leak of [
    'process.env, error_description',
    'error.message',
    'error.msg',
    'String(error)',
  ]) {
    assert.ok(
      !code.includes(leak),
      `the callback must not forward provider text (${leak})`
    );
  }
  // Every bounce carries one of the reviewed codes.
  const bounces = code.match(/buildLoginRedirect\([^)]*\)/g) || [];
  assert.ok(bounces.length >= 3, 'expected the callback to bounce on failure');
  for (const bounce of bounces) {
    const named = ['sign_in_failed', 'link_expired', 'rate_limited', 'unavailable', 'reason'];
    const carriesCode = named.some((n) => bounce.includes(n));
    const isBareBounce = /buildLoginRedirect\((APP_ENTRY_PATH|next)\)/.test(bounce);
    assert.ok(
      carriesCode || isBareBounce,
      `every failure bounce must carry a reviewed code: ${bounce}`
    );
  }
});

test('the callback classifies a failure by status, never by message', () => {
  const code = stripComments(callback);
  assert.match(code, /const status = \(error as \{ status\?: number \}\)\.status/);
  assert.ok(
    !/error\.message|String\(error\)|`\$\{error/.test(code),
    'classification must not read the failure text'
  );
});

test('no secret can reach a server log', () => {
  const code = stripComments(callback);
  // The response body carries `api_token`. Logging it wrote a live bearer to
  // the log; on a 4xx it could echo the address back too.
  assert.ok(!code.includes('res.text()'), 'the response body must never be logged');
  assert.ok(!code.includes('res.json()) as string'), 'no body stringification into a log');
  for (const forbidden of [
    'console.error(\'[auth/callback] web sign-in error:\', e)',
    'console.log(accessToken',
    'console.error(accessToken',
    'JSON.stringify(session)',
  ]) {
    assert.ok(!code.includes(forbidden), `must not log ${forbidden}`);
  }
  // Every console call in this file must pass only fixed strings and a status.
  // The ARGUMENTS are judged, not the `console.error` method name itself.
  const logged = [...code.matchAll(/console\.(?:error|log|warn)\(([^;]*)\);/g)].map(
    (m) => m[1]
  );
  assert.ok(logged.length > 0, 'expected some diagnostics to remain');
  for (const args of logged) {
    for (const secretish of [
      'accessToken',
      'api_token',
      'await res',
      'res.text',
      'session',
      'email',
    ]) {
      assert.ok(
        !args.includes(secretish),
        `a diagnostic must not carry ${secretish}: ${args}`
      );
    }
    // No bare caught-failure identifier either — `e`, `err`, `error` as an
    // argument is how a host name reaches a log.
    assert.ok(
      !/\b(?:e|err|error|failure)\b/.test(args),
      `a diagnostic must not carry the caught failure: ${args}`
    );
  }
});

test('the login page renders a mapped sentence and holds no provider text', () => {
  const code = stripComments(loginPage);
  assert.match(emailCopy, /const EMAIL_AUTH_COPY: Record<EmailAuthOutcome, string>/);
  assert.ok(
    code.includes('{EMAIL_AUTH_COPY[outcome]}'),
    'the rendered sentence must come from the mapper'
  );
  // The code that selects the sentence is a reviewed value or nothing. An
  // unrecognised one is dropped rather than displayed, so a new upstream
  // failure shape cannot arrive on screen as itself.
  assert.ok(
    code.includes('sanitizeEmailAuthOutcome'),
    'the rendered code must be sanitized to the reviewed set'
  );
  // The state cannot hold a message at all.
  assert.ok(
    !/useState<string \| null>\(null\)/.test(code) || !code.includes('setError('),
    'no failure state may hold a free string'
  );
  for (const leak of ['{error}', 'err.message', 'error.message', 'setError(err']) {
    assert.ok(!code.includes(leak), `the login page must not render ${leak}`);
  }
});

test('sending a link answers the same way for a known and an unknown address', () => {
  const code = stripComments(loginPage);
  // A plain rejection still shows the confirmation. Only failures an outsider
  // can already observe — throttling and an outage — are surfaced.
  assert.match(
    code,
    /reason === 'unknown_failure' \? 'check_your_email' : reason/,
    'a rejected send must not distinguish a registered address'
  );
  // The same property for the flows the web gained in the remediation: the
  // route answers 200 with an outcome whether or not the address exists, so
  // the HTTP status cannot become the oracle the body avoids being.
  for (const route of ['register', 'resend', 'reset']) {
    const handler = read(`src/app/api/auth/email/${route}/route.ts`);
    const statuses = [...handler.matchAll(/\{\s*status:\s*(\d{3})\s*\}/g)].map((m) => m[1]);
    assert.ok(statuses.length > 0, `${route} returns no explicit status`);
    assert.deepEqual(
      [...new Set(statuses)],
      ['200'],
      `${route} varies its status, which distinguishes a registered address`
    );
  }
});

test('the reviewed sentences name no implementation detail', () => {
  // Join the entries whose sentence wrapped onto its own line, so a long
  // sentence is not silently exempt from the ban below.
  const flattened = emailCopy.replace(/:\s*\n\s+/g, ': ');
  const sentences = [...flattened.matchAll(/^\s{2}\w+: (['"])(.*?)\1,$/gm)].map((m) => m[2]);
  assert.ok(sentences.length >= 4, 'expected the reviewed copy block to be found');
  const forbidden = [
    'backend', 'server', 'provider', 'supabase', 'endpoint', 'token', 'bearer',
    'http', '://', 'api key', 'status', '401', '403', '429', '500', '503',
  ];
  for (const sentence of sentences) {
    for (const term of forbidden) {
      assert.ok(
        !sentence.toLowerCase().includes(term),
        `login copy names “${term}”: ${sentence}`
      );
    }
    assert.ok(sentence.length > 12, `copy must be a sentence: ${sentence}`);
  }
});

test('the bounced-back reason is read after mount, not during render', () => {
  const code = stripComments(loginPage);
  // The callback bounces to /login?error=<code>. The page has to read it, or
  // the only sentence explaining a failed sign-in never appears at all.
  assert.ok(
    code.includes("new URLSearchParams(window.location.search).get('error')"),
    'the login page must read the bounced-back reason'
  );
  // But NOT during render. This page is prerendered to static HTML, whose
  // markup never contains the alert paragraph, so deriving the code in a
  // `useState` initializer makes the hydration render produce an element the
  // server tree does not have — a structural mismatch React reports as an
  // error and recovers from by discarding the server tree.
  assert.ok(
    !/useState[^;]*window\.location/.test(code),
    'the reason must not be derived in a useState initializer (hydration mismatch)'
  );
  assert.match(
    code,
    /useEffect\(\(\) => \{[\s\S]*?window\.location\.search[\s\S]*?\}, \[\]\)/,
    'the reason must be read in a mount effect'
  );
});

test('a web sign-in is tagged so the registration ledger can count it', () => {
  assert.match(
    stripComments(callback),
    /body: JSON\.stringify\(\{ access_token: accessToken, app_version: 'web-114' \}\)/,
    'the web surface must identify its build to the registration ledger'
  );
});
