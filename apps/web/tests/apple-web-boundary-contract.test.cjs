// Source-contract guards for the direct Tono Apple web OAuth boundary.
//
// These read the SHIPPING source and assert the load-bearing safety properties
// hold in the bytes that deploy — the properties a unit test can't see because
// they are about what the code must NEVER contain or do:
//   * the login page must never start Apple through Supabase, and must never
//     embed the contaminated sibling id (parentscript.app);
//   * the start route must fail closed when the boundary is unconfigured;
//   * the callback must validate state, verify the id_token, and hand off to
//     the canonical backend — never to Supabase;
//   * neither route may log a token, code, or bearer.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = (relative) => fs.readFileSync(path.join(__dirname, '..', relative), 'utf8');

const loginPage = read('src/app/login/page.tsx');
const startRoute = read('src/app/api/auth/apple/start/route.ts');
const callbackRoute = read('src/app/api/auth/apple/callback/route.ts');
const lib = read('src/lib/apple-web-auth.ts');

const stripComments = (src) =>
  src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/[^\n]*/g, '$1');

// --- the contaminated sibling id must appear NOWHERE in shipped bytes -------

test('no boundary source contains the sibling product id', () => {
  for (const [name, src] of [
    ['login page', loginPage],
    ['start route', startRoute],
    ['callback route', callbackRoute],
    ['apple-web-auth lib', lib],
  ]) {
    assert.ok(!src.includes('parentscript'), `${name} must not contain the sibling id`);
  }
});

// --- login page never starts Apple through Supabase -------------------------

test('the login page never calls Supabase OAuth for apple', () => {
  const code = stripComments(loginPage);
  // The only signInWithOAuth call may be for google; apple must not appear as a
  // provider argument to it.
  assert.doesNotMatch(
    code,
    /signInWithOAuth\(\s*\{[^}]*provider:\s*['"]apple['"]/,
    'apple must never be passed to Supabase signInWithOAuth',
  );
  assert.doesNotMatch(
    code,
    /oauth\(\s*['"]apple['"]\s*\)/,
    'the Supabase oauth() helper must never be invoked for apple',
  );
});

test('the login page starts Apple via the direct, Tono-owned route', () => {
  const code = stripComments(loginPage);
  assert.match(code, /\/api\/auth\/apple\/start/, 'apple button must navigate to the direct start route');
  // The direct start navigation must be gated behind the fail-closed flag.
  assert.match(code, /APPLE_OAUTH_ENABLED/);
});

// --- start route: fail closed, form_post, secure transaction cookies --------

test('the start route fails closed when the boundary is not configured', () => {
  const code = stripComments(startRoute);
  assert.match(code, /readAppleWebConfig\(process\.env\)/);
  // A missing config must bounce to login, never proceed to Apple.
  assert.match(code, /if\s*\(!config\)[\s\S]{0,160}buildLoginRedirect/);
});

test('the start route sets HttpOnly, Secure, SameSite=None transaction cookies', () => {
  const code = stripComments(startRoute);
  assert.match(code, /httpOnly:\s*true/);
  assert.match(code, /secure:\s*true/);
  // SameSite=None is REQUIRED to survive Apple's cross-site form_post callback.
  assert.match(code, /sameSite:\s*'none'/);
});

// --- callback route: state + verify + canonical handoff, no Supabase --------

test('the callback validates state before doing anything with the code', () => {
  const code = stripComments(callbackRoute);
  assert.match(code, /state\s*!==\s*expectedState/);
});

test('the callback verifies the id_token and hands off to the canonical backend', () => {
  const code = stripComments(callbackRoute);
  assert.match(code, /verifyAppleIdToken\(/);
  assert.match(code, /\/v1\/auth\/apple\/web/);
  // It must never route Apple through Supabase.
  assert.ok(!/supabase/i.test(code), 'the callback must not touch Supabase');
});

test('the callback classifies backend failures by status, never by body text', () => {
  const code = stripComments(callbackRoute);
  assert.match(code, /res\.status\s*===\s*429/);
  assert.match(code, /res\.status\s*>=\s*500/);
});

// --- neither route may log a secret -----------------------------------------

test('the boundary never logs a token, code, or bearer', () => {
  for (const [name, src] of [['start', startRoute], ['callback', callbackRoute]]) {
    const code = stripComments(src);
    for (const secret of ['identity_token', 'id_token', 'client_secret', 'api_token', 'code']) {
      assert.doesNotMatch(
        code,
        new RegExp(`console\\.(log|error|warn|info)\\([^)]*${secret}`),
        `${name} route must not log ${secret}`,
      );
    }
  }
});

// --- lib: no Supabase, WebCrypto only, fail-closed config -------------------

test('the crypto lib is self-contained (no Supabase usage, no jsonwebtoken/jose)', () => {
  const code = stripComments(lib);
  // The word "Supabase" may appear in prose explaining what this replaces, but
  // there must be no Supabase IMPORT or client usage in the actual code.
  assert.ok(!/from\s+['"][^'"]*supabase[^'"]*['"]/i.test(code), 'must not import Supabase');
  assert.ok(!/signInWithOAuth/.test(code), 'must not use Supabase OAuth');
  assert.ok(!/from\s+['"]jsonwebtoken['"]/.test(code));
  assert.ok(!/from\s+['"]jose['"]/.test(code));
});
