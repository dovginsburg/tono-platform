import assert from 'node:assert/strict';
import test from 'node:test';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Regression guard for the basePath double-prefix defect.
//
// next.config.js sets basePath: '/app', so Next's <Link> automatically
// prepends '/app' to every href. Writing <Link href="/app/app"> therefore
// resolves to /app/app/app — a 404 — and <Link href="/app/app/history"> to
// /app/app/app/history. Both were live dead-ends in the post-checkout / editor
// surfaces of the paid loop. The correct, basePath-relative hrefs are "/app"
// (the editor) and "/app/history".
//
// A raw window.location.assign('/app/login') and a raw <form action="/app/...">
// are NOT processed by Next basePath and MUST include the /app prefix, so we
// only scan JSX href attributes (Link/anchor), never form actions.

const appDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app');

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (p.endsWith('.tsx') || p.endsWith('.ts')) out.push(p);
  }
  return out;
}

test('no <Link>/anchor href double-prefixes the /app basePath', () => {
  const offenders: string[] = [];
  for (const file of walk(appDir)) {
    const src = readFileSync(file, 'utf8');
    // href="/app/app..." means the basePath is already baked in — the bug.
    if (/href="\/app\/app(\/|")/.test(src)) offenders.push(file);
  }
  assert.deepEqual(
    offenders,
    [],
    `basePath double-prefix in href (use "/app" and "/app/history", not "/app/app"): ${offenders.join(', ')}`
  );
});

test('every raw <form action> to a Next route carries the /app basePath', () => {
  // Raw HTML form actions are not rewritten by Next basePath, so an
  // action pointing at an app API route MUST include the /app prefix or the
  // POST 404s (silent sign-out failure was exactly this bug).
  const offenders: string[] = [];
  for (const file of walk(appDir)) {
    const src = readFileSync(file, 'utf8');
    const matches = src.match(/action="([^"]+)"/g) ?? [];
    for (const m of matches) {
      const url = m.slice('action="'.length, -1);
      if (url.startsWith('/api/')) offenders.push(`${file}: ${url}`);
    }
  }
  assert.deepEqual(
    offenders,
    [],
    `raw form action missing /app basePath (use "/app/api/...", not "/api/..."): ${offenders.join(', ')}`
  );
});
