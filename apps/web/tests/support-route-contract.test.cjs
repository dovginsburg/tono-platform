// Support-route contract (2026-08-04).
//
// App Store Connect submits Support URL https://tonoit.com/support. That apex
// path was returning 404 for two compounding reasons, both pinned here:
//
//   1. No page existed at src/app/support — so even /app/support 404'd.
//   2. Even with the page, the apex /support only resolves because vercel.json
//      rewrites /support -> /app/support. Next.js mounts every route under
//      basePath '/app', so the bare apex path is served ONLY by that rewrite —
//      exactly like /about, /contact, /privacy, /terms. Miss it and the
//      anonymous direct-load / refresh that App Review performs 404s again.
//
// The deep-link assertion below is red-capable: delete the page OR the rewrite
// and it fails, mirroring the production 404. It follows the same shape as
// src/lib/next-rewrites.test.ts::'apex SEO surface is still served by vercel.json'.
//
// The remaining assertions pin the truthful, on-brand help copy the brief
// requires: official support mailto sourced from lib/contact (never a
// hand-typed address), privacy/terms/account links, a what-to-include list, a
// clear non-emergency limitation, an anonymous (server-rendered) page, and the
// absence of any internal identity or unearned claim (in-app tickets, a login
// requirement, a response SLA, or medical/therapy support).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WEB_ROOT = path.join(__dirname, '..');
const PAGE_REL = 'src/app/support/page.tsx';
const PAGE_PATH = path.join(WEB_ROOT, PAGE_REL);

const read = (relative) => fs.readFileSync(path.join(WEB_ROOT, relative), 'utf8');

// Strip // and /* */ comments so copy assertions see only rendered text — the
// header comment legitimately names the forbidden claims in order to forbid
// them. Same shape as tests/apple-web-boundary-contract.test.cjs.
const stripComments = (src) =>
  src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/[^\n]*/g, '$1');

// --- route exists and is a real page ----------------------------------------

test('a support page exists at src/app/support and default-exports a component', () => {
  assert.ok(fs.existsSync(PAGE_PATH), `${PAGE_REL} must exist so /app/support renders`);
  const src = read(PAGE_REL);
  assert.match(src, /export default function \w+Page\(/, 'must default-export a page component');
});

// --- the deep-link: apex /support is served by vercel.json (the 404 fix) -----

test('vercel.json maps apex /support -> /app/support to a real page', () => {
  const vercel = JSON.parse(read('vercel.json'));
  const rule = vercel.rewrites.find((r) => r.source === '/support');
  assert.ok(
    rule,
    'vercel.json must rewrite apex /support so the App Store Support URL ' +
      'https://tonoit.com/support direct-loads and refreshes anonymously (the 404 fix)',
  );
  // Apex source, basePath-mounted destination — the pattern every marketing
  // page follows. A destination missing the /app prefix would itself 404.
  assert.ok(!rule.source.startsWith('/app'), 'the /support source is the bare apex path');
  assert.equal(rule.destination, '/app/support', 'destination is the basePath-mounted route');
  // The destination must resolve to a page that actually exists.
  const routeRel = rule.destination.replace(/^\/app/, ''); // '/support'
  assert.ok(
    fs.existsSync(path.join(WEB_ROOT, 'src', 'app', routeRel, 'page.tsx')),
    `vercel.json points /support at ${rule.destination}, but no page serves ${routeRel}`,
  );
});

// --- descriptive metadata (title + copy) ------------------------------------

test('the support page ships descriptive title and description metadata', () => {
  const src = read(PAGE_REL);
  assert.match(src, /export const metadata\b/, 'must export Next metadata');
  assert.match(src, /title:\s*'support — tono'/, 'title must name the support surface');
  const desc = src.match(/description:\s*\n?\s*'([^']+)'/);
  assert.ok(desc && desc[1].length >= 40, 'description must be a non-empty, descriptive sentence');
  // The visible page heading is present and on-brand (lowercase).
  assert.match(src, /<h1[^>]*>[\s\S]*?help with tono\.[\s\S]*?<\/h1>/);
});

// --- official support mailto, sourced from the contact module ---------------

test('the primary support contact is support@tonoit.com via the contact module', () => {
  const src = read(PAGE_REL);
  assert.match(src, /from '(\.\.\/)+lib\/contact'/, 'must import the official contact identity');
  assert.match(src, /tonoMailto\('support'\)/, 'the mailto must be built for the support channel');
  assert.match(src, /TONO_CONTACT\.support/, 'the visible address comes from the module');
  // No hand-typed mailbox: a mailto: literal followed by a real local-part char
  // is the leak the brand guard bans; ours is an interpolated tonoMailto().
  assert.ok(
    !/mailto:[A-Za-z0-9._%+-]/.test(src),
    'must not hard-code a mailto: address literal — use tonoMailto()',
  );
});

// --- the help copy the brief requires ---------------------------------------

test('the page carries account/billing/access, privacy, and terms help links', () => {
  const src = read(PAGE_REL);
  assert.match(src, /href="\/account"/, 'web billing points at the account page');
  assert.match(src, /href="\/privacy"/, 'links the privacy page');
  assert.match(src, /href="\/terms"/, 'links the terms page');
  // "what to include" guidance so a support request is actionable on first reply.
  assert.match(src, /what to include/i);
  assert.match(src, /account/i);
});

test('subscription cancellation guidance follows the purchase channel', () => {
  const copy = stripComments(read(PAGE_REL)).toLowerCase();

  assert.match(
    copy,
    /app store\s+purchase[\s\S]*apple id\s+subscriptions/,
    'App Store purchases must point to Apple ID Subscriptions',
  );
  assert.match(
    copy,
    /google play\s+purchase[\s\S]*google play\s+subscriptions/,
    'Google Play purchases must point to Google Play subscriptions',
  );
  assert.match(
    copy,
    /web\s+purchase[\s\S]*href="\/account"[\s\S]*stripe billing portal/,
    'web purchases must point to the account page and identify its Stripe portal',
  );
  assert.ok(
    !/manage your subscription[\s\S]{0,160}href="\/account"/.test(copy),
    'must not claim every subscription can be managed from the web account page',
  );
  assert.match(
    copy,
    /not sure where you purchased[\s\S]*can't access[\s\S]*tonomailto\('support'\)/,
    'uncertain purchase channel and access problems must fall back to support',
  );
});

test('the page states a clear non-emergency limitation', () => {
  const text = stripComments(read(PAGE_REL)).toLowerCase();
  assert.match(text, /not (an )?emergency|not for emergencies/);
  assert.ok(
    text.includes('crisis') || text.includes('emergency number') || text.includes('emergency services'),
    'must direct emergencies to local/crisis resources',
  );
});

// --- anonymous load + no internal identity or unearned claim ----------------

test('the support page renders anonymously (server component, no auth gate)', () => {
  const src = read(PAGE_REL);
  assert.ok(!src.includes("'use client'"), 'must be a server component so it direct-loads anonymously');
  assert.ok(!/\bredirect\(/.test(src), 'must not redirect — App Review loads it signed-out');
});

test('the support page names no internal identity and makes no unearned claim', () => {
  // Identities are scanned in raw bytes (comments included) — the same
  // deliberate strictness as tests/brand-contact-identity.test.cjs, so a stray
  // operator path in a comment trips too.
  const raw = read(PAGE_REL).toLowerCase();
  for (const banned of ['ezra', 'agentmail', 'parentscript']) {
    assert.ok(!raw.includes(banned), `support page must not surface “${banned}”`);
  }
  // Unearned claims are about rendered copy: in-app tickets, a response SLA, or
  // medical/therapy support. Scan with comments stripped.
  const copy = stripComments(read(PAGE_REL)).toLowerCase();
  assert.ok(!/submit a ticket|open a ticket|ticketing/.test(copy), 'no in-app ticketing claim');
  assert.ok(!/\bwithin \d+ (hours?|business days?)\b/.test(copy), 'no response-time SLA claim');
  assert.ok(!/therap(y|ist|eutic)|counsel(ing|or)/.test(copy), 'no therapy/counseling claim');
});
