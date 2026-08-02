// Source-contract tests for the account / payment-history / password UI work.
//
// These read the shipped source (the repo's established .test.cjs style) and
// assert the structural guarantees that a rendered-DOM test would otherwise
// need a browser harness to check: an accessible password reveal on every
// password field, a fail-closed OAuth capability gate, no raw account id in the
// editor chrome, and the payment-history surface wired end to end.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SRC = path.join(__dirname, '..', 'src');
const read = (p) => fs.readFileSync(path.join(SRC, p), 'utf8');

test('PasswordField exposes an accessible show/hide toggle', () => {
  const src = read('app/PasswordField.tsx');
  assert.match(src, /type=\{visible \? 'text' : 'password'\}/);
  assert.match(src, /aria-pressed=\{visible\}/);
  assert.match(src, /aria-controls=/);
  assert.match(src, /aria-label=\{visible \? 'Hide password' : 'Show password'\}/);
});

test('login page routes both password entry points through PasswordField', () => {
  const src = read('app/login/page.tsx');
  assert.match(src, /import PasswordField from '\.\.\/PasswordField'/);
  assert.match(src, /<PasswordField/);
  // No bare masked <input type="password"> left behind (that would have no toggle).
  assert.doesNotMatch(src, /type="password"/);
});

test('reset password form uses PasswordField for new + confirm fields', () => {
  const src = read('app/auth/reset/reset-client.tsx');
  const count = (src.match(/<PasswordField/g) || []).length;
  assert.equal(count, 2, 'both new and confirm password fields should use PasswordField');
  assert.doesNotMatch(src, /type="password"/);
});

test('Google OAuth button is gated on a fail-closed capability flag', () => {
  const src = read('app/login/page.tsx');
  assert.match(src, /OAUTH_CONFIGURED = Boolean\(SUPABASE_URL && SUPABASE_ANON_KEY\)/);
  // The Google button renders only when the provider is configured.
  assert.match(src, /\{OAUTH_CONFIGURED \?/);
});

test('Apple OAuth button has a SEPARATE fail-closed gate, independent of Supabase', () => {
  const src = read('app/login/page.tsx');
  // Apple is now a DIRECT, Tono-owned flow — its gate is INDEPENDENT of the
  // Supabase (OAUTH_CONFIGURED) gate: the direct boundary works with no Supabase
  // provider at all. It still needs an attested Tono Services ID or it must not
  // render (never send users to the sibling product's consent screen).
  assert.match(src, /APPLE_OAUTH_ENABLED = appleWebSignInEnabled\(/);
  // The old Supabase-coupled gate must be gone.
  assert.doesNotMatch(src, /APPLE_OAUTH_ENABLED\s*=\s*\n?\s*OAUTH_CONFIGURED &&/);
  assert.match(src, /process\.env\.NEXT_PUBLIC_APPLE_WEB_SERVICES_ID/);
  // The Apple button is rendered under the Apple gate, not the generic one.
  assert.match(src, /\{APPLE_OAUTH_ENABLED \?/);
  // A truthful fallback replaces the button when the binding is unverified.
  assert.match(src, /APPLE_WEB_UNAVAILABLE_COPY/);
});

test('Apple sign-in never runs through Supabase OAuth (direct Tono boundary only)', () => {
  const src = read('app/login/page.tsx');
  // The button starts OUR own flow (a top-level nav to the start route), never
  // Supabase's provider OAuth.
  assert.match(src, /onClick=\{startApple\}/);
  assert.match(src, /\/api\/auth\/apple\/start/);
  // Supabase signInWithOAuth is never invoked for Apple, in any spelling.
  assert.doesNotMatch(src, /oauth\('apple'\)/);
  assert.doesNotMatch(src, /signInWithOAuth\([^)]*apple/i);
  // The Supabase oauth helper is narrowed to google so 'apple' cannot be passed.
  assert.match(src, /const oauth = async \(provider: 'google'\)/);
});

test('no compiled web source embeds a foreign (sibling-product) Apple client id', () => {
  // The contamination is a Supabase dashboard binding, and it must never be
  // "fixed" by hard-coding the sibling's client id into a shipped artifact.
  // The branding gate + direct boundary are allowlists by Tono shape precisely
  // so this stays true even in the new direct Apple modules.
  const files = [
    'app/login/page.tsx',
    'lib/apple-oauth-binding.ts',
    'lib/apple-web-auth.ts',
    'lib/supabase-client.ts',
    'app/auth/callback/route.ts',
    'app/api/auth/apple/start/route.ts',
    'app/api/auth/apple/callback/route.ts',
  ];
  for (const f of files) {
    const src = read(f).toLowerCase();
    assert.doesNotMatch(src, /parentscript/, `${f} must not embed the sibling client id`);
  }
});

test('editor chrome no longer prints a raw account/user id', () => {
  const src = read('app/app/editor-client.tsx');
  assert.doesNotMatch(src, /userId\.slice\(/);
  // History is written under the per-account namespace.
  assert.match(src, /historyStorageKey/);
  assert.match(src, /saveToHistory\(\s*\{[\s\S]*?\},\s*userId,?\s*\)/);
});

test('history page reads the per-account namespace, not a global key', () => {
  const src = read('app/app/history/page.tsx');
  assert.doesNotMatch(src, /const STORAGE_KEY = 'tono:history'/);
  assert.match(src, /historyStorageKey/);
  assert.match(src, /auth\.getUser\(\)/);
});

test('payment history surface is wired end to end', () => {
  const route = read('app/api/account/payment-history/route.ts');
  assert.match(route, /\/v1\/account\/payment-history/);
  assert.match(route, /tono_api_token/);

  const comp = read('app/account/PaymentHistory.tsx');
  assert.match(comp, /\/api\/account\/payment-history/);
  // Export control present; no raw provider/transaction id fields rendered.
  assert.match(comp, /export/);
  assert.doesNotMatch(comp, /original_transaction_id/);

  const page = read('app/account/page.tsx');
  assert.match(page, /<PaymentHistory \/>/);
  assert.match(page, /<SignOutButton \/>/);
});

test('sign-out purges device-local history before clearing the session', () => {
  const src = read('app/account/SignOutButton.tsx');
  assert.match(src, /purgeAllHistory/);
  assert.match(src, /\/app\/api\/auth\/signout/);
});

test('account page never labels a non-pro account "free" (no free tier exists)', () => {
  const src = read('app/account/page.tsx');
  // The plan label ternary must not resolve to the word "free".
  assert.doesNotMatch(src, /is_pro \? 'tono pro' : 'free'/);
  assert.match(src, /is_pro \? 'tono pro' : 'no active plan'/);
});

test('editor no longer shows a fake "saved" / "auto-saved" state for the draft', () => {
  const src = read('app/app/editor-client.tsx');
  // The draft is never persisted, so the composer must not claim it is saved.
  assert.doesNotMatch(src, /saved · just now/);
  assert.doesNotMatch(src, /draft auto-saved/);
});

test('payment history renders a verified amount only when normalized, never a raw one', () => {
  const comp = read('app/account/PaymentHistory.tsx');
  // Amount is gated on BOTH minor units and currency being present.
  assert.match(comp, /formatAmount\(item\.amount_minor, item\.currency\)/);
  assert.match(comp, /Intl\.NumberFormat/);
  assert.match(comp, /plan price/);
});

test('history empty state explains device-local storage + second-device expectation', () => {
  const src = read('app/app/history/page.tsx');
  assert.match(src, /stored on this device only/);
  assert.match(src, /a new browser or phone starts empty/);
});

test('landing hero ships an interactive canned demo, not a live anonymous rewrite', () => {
  const demo = read('app/DemoRewrite.tsx');
  // Precomputed constants, no backend call from the demo.
  assert.match(demo, /SAMPLE_REWRITES/);
  assert.doesNotMatch(demo, /fetch\(/);
  // Honest labelling — never claims a live rewrite ran.
  assert.match(demo, /canned sample · not a live rewrite/);

  const page = read('app/page.tsx');
  assert.match(page, /<DemoRewrite \/>/);
});
