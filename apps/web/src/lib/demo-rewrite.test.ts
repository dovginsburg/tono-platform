import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  type Axis,
  DEMO_TONE_ORDER,
  DEMO_SAMPLE_DRAFT,
  DEMO_REWRITES,
  DEMO_SAMPLE_LABEL,
  demoRewriteFor,
  demoPickConfirmation,
} from './demo-rewrite.ts';

const here = dirname(fileURLToPath(import.meta.url));
const readSrc = (...parts: string[]) => readFileSync(join(here, '..', ...parts), 'utf8');

// Strip // line and /* */ block comments so "no backend call" assertions test
// executable code, not documentation that legitimately names endpoints.
const stripComments = (src: string) =>
  src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/[^\n]*/g, '$1');

// Regex that catches an unsupported latency claim in either digit or spelled
// form: "8 seconds", "in 8 seconds", "two seconds", "ten seconds", etc.
const TIMING_CLAIM =
  /\b(?:in\s+)?(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s*seconds?\b/i;

// ---------------------------------------------------------------------------
// 1. No unsupported timing claim survives in public web copy or metadata.
//
// The live landing headline claimed "in 8 seconds", an unsupported latency
// number the founder rightly rejected. It must not reappear anywhere a
// signed-out visitor (or a crawler reading metadata) can see it.
// ---------------------------------------------------------------------------

test('public web copy and metadata make no timing/latency claim', () => {
  for (const rel of [
    ['app', 'page.tsx'],
    ['app', 'layout.tsx'],
    ['app', 'app', 'editor-client.tsx'],
    ['app', 'DemoRewrite.tsx'],
    ['lib', 'demo-rewrite.ts'],
  ]) {
    const src = readSrc(...rel);
    assert.ok(
      !TIMING_CLAIM.test(src),
      `${rel.join('/')} still contains a timing claim: ${(src.match(TIMING_CLAIM) || [])[0]}`
    );
  }
});

// ---------------------------------------------------------------------------
// 2. The demo content is fixed, complete, and in canonical tone order.
// ---------------------------------------------------------------------------

test('the sample draft is a single fixed, non-empty string', () => {
  assert.equal(typeof DEMO_SAMPLE_DRAFT, 'string');
  assert.ok(DEMO_SAMPLE_DRAFT.trim().length > 0);
});

test('exactly the four tones appear once each, in canonical order', () => {
  assert.deepEqual(DEMO_TONE_ORDER, ['warmer', 'clearer', 'funnier', 'safer']);
  assert.deepEqual(
    DEMO_REWRITES.map((r) => r.axis),
    ['warmer', 'clearer', 'funnier', 'safer']
  );
});

test('every tone has a distinct, non-empty rewrite', () => {
  const texts = DEMO_REWRITES.map((r) => r.text);
  for (const t of texts) assert.ok(t.trim().length > 0);
  assert.equal(new Set(texts).size, texts.length, 'rewrites must all differ');
});

// ---------------------------------------------------------------------------
// 3. The decision experience is real: picking a tone resolves a wording and a
//    confirmation deterministically (no I/O, same input → same output).
// ---------------------------------------------------------------------------

test('demoRewriteFor resolves the canned wording for each tone', () => {
  for (const r of DEMO_REWRITES) {
    assert.equal(demoRewriteFor(r.axis), r.text);
  }
  assert.throws(() => demoRewriteFor('warmest' as unknown as Axis), /unknown demo tone/);
});

test('demoPickConfirmation names the picked tone as the one to send', () => {
  for (const axis of DEMO_TONE_ORDER) {
    const line = demoPickConfirmation(axis);
    assert.ok(line.includes(axis), `confirmation must name ${axis}`);
    assert.ok(/send/i.test(line), 'confirmation must frame it as sending');
  }
});

// ---------------------------------------------------------------------------
// 4. The demo is a canned sample and NEVER a backend call.
//
// It must not reach any rewrite service: no fetch, no /api/, no analyze
// endpoint, no XHR/SSE. The only browser API allowed is the clipboard.
// ---------------------------------------------------------------------------

test('DemoRewrite makes no network/backend call', () => {
  const src = stripComments(readSrc('app', 'DemoRewrite.tsx'));
  for (const forbidden of [
    /\bfetch\s*\(/,
    /\/api\//,
    /\/analyze\b/,
    /XMLHttpRequest/,
    /EventSource/,
    /axios/,
    /supabase/i,
  ]) {
    assert.ok(!forbidden.test(src), `DemoRewrite must not use ${forbidden}`);
  }
});

test('the demo data module is pure constants — no I/O', () => {
  const src = stripComments(readSrc('lib', 'demo-rewrite.ts'));
  for (const forbidden of [/\bfetch\s*\(/, /\/api\//, /require\s*\(/, /import\s+.*from/]) {
    assert.ok(!forbidden.test(src), `demo-rewrite.ts must not use ${forbidden}`);
  }
});

// ---------------------------------------------------------------------------
// 5. The sample is labeled accurately and claims no free live rewriting.
// ---------------------------------------------------------------------------

test('the canned-sample label is present and honest', () => {
  assert.ok(/canned sample/i.test(DEMO_SAMPLE_LABEL));
  assert.ok(/not a live rewrite/i.test(DEMO_SAMPLE_LABEL));
});

test('DemoRewrite renders the canned-sample label and a pre-signup pick', () => {
  const src = readSrc('app', 'DemoRewrite.tsx');
  assert.ok(src.includes(DEMO_SAMPLE_LABEL), 'must render the canned-sample label');
  assert.ok(/no account needed/i.test(src), 'must state no account is needed for the sample');
  // The decision interaction: a radiogroup of picks, not just an animation.
  assert.ok(/radiogroup/.test(src), 'must offer a pick (radiogroup)');
  assert.ok(/onClick/.test(src), 'must be interactive');
  assert.ok(/aria-checked/.test(src), 'the pick must reflect selection state');
});

test('the landing page claims no free LIVE rewriting of the visitor’s drafts', () => {
  const page = readSrc('app', 'page.tsx');
  // Free applies to the trial and to the canned sample — never to live rewrites.
  assert.ok(!/free\s+(live\s+)?rewrite/i.test(page), 'must not offer a free live rewrite');
  // Own-draft rewriting is gated behind the paid trial.
  assert.ok(/14-day free trial/i.test(page), 'own-draft rewriting routes to the trial');
  assert.ok(page.includes('<DemoRewrite'), 'the landing hero mounts the canned demo');
});
