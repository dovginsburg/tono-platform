import assert from 'node:assert/strict';
import test from 'node:test';
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { BASE_PATH, apiPath } from './auth-redirects.ts';

// Regression guard for the "route handler is unreachable in production" defect.
//
// next.config.js sets basePath: '/app', so every handler under
// src/app/api/**/route.ts is served at /app/api/... . Next rewrites <Link href>
// for basePath but does NOT rewrite fetch(), raw <form action>, or
// window.location — those resolve against the document ORIGIN. So a bare
// fetch('/api/portal') requests https://tonoit.com/api/portal.
//
// Apex /api/* resolves ONLY for paths hand-listed in vercel.json's rewrite
// table. That table listed /api/checkout, /api/health, /api/analyze and
// /api/me — so "Manage billing" (/api/portal) and every passkey route
// (/api/passkey/*) 404'd in production while the four listed ones worked.
//
// Two invariants keep that from recurring:
//   1. client code addresses handlers through apiPath(), never a bare /api path;
//   2. every path passed to apiPath() resolves to a real route handler.

const here = dirname(fileURLToPath(import.meta.url));
const appDir = join(here, '..', 'app');
const apiDir = join(appDir, 'api');
const webRoot = join(here, '..', '..');

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (p.endsWith('.tsx') || p.endsWith('.ts')) out.push(p);
  }
  return out;
}

/** Route handlers on disk, as app-relative paths: '/api/portal', ... */
function declaredRoutes(): string[] {
  const out: string[] = [];
  for (const file of walk(apiDir)) {
    if (!file.endsWith(`${'route'}.ts`)) continue;
    const rel = file.slice(appDir.length).replace(/\/route\.ts$/, '');
    out.push(rel);
  }
  return out.sort();
}

/** A route path with [dynamic] segments turned into a matcher. */
function routeMatcher(route: string): RegExp {
  const pattern = route
    .split('/')
    .map((seg) => (seg.startsWith('[') && seg.endsWith(']') ? '[^/]+' : seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
    .join('/');
  return new RegExp(`^${pattern}$`);
}

test('apiPath prefixes the configured basePath', () => {
  assert.equal(apiPath('/api/portal'), `${BASE_PATH}/api/portal`);
  assert.equal(apiPath('api/portal'), `${BASE_PATH}/api/portal`, 'tolerates a missing leading slash');
  assert.equal(apiPath('/api/passkey/abc'), `${BASE_PATH}/api/passkey/abc`);
  assert.ok(apiPath('/api/me').startsWith('/app/'), 'must be basePath-qualified, not apex-relative');
});

test('no client code addresses an API route with a bare /api path', () => {
  // fetch('/api/...'), fetch(`/api/...`), <form action="/api/...">,
  // window.location.assign('/api/...') — all bypass basePath.
  const offenders: string[] = [];
  for (const file of walk(appDir)) {
    if (file.endsWith('/route.ts')) continue; // server handlers call absolute backend URLs
    const src = readFileSync(file, 'utf8');
    const patterns: [RegExp, string][] = [
      [/fetch\(\s*['"`]\/api\//g, 'bare fetch'],
      [/action=["']\/api\//g, 'bare form action'],
      [/window\.location\.(?:assign|replace|href\s*=)\s*\(?\s*['"`]\/api\//g, 'bare navigation'],
    ];
    for (const [re, label] of patterns) {
      if (re.test(src)) offenders.push(`${file.slice(webRoot.length)} (${label})`);
    }
  }
  assert.deepEqual(
    offenders,
    [],
    `use apiPath('/api/...') — a bare /api path resolves at the apex and 404s ` +
      `unless hand-listed in vercel.json: ${offenders.join(', ')}`
  );
});

test('every apiPath() argument resolves to a real route handler', () => {
  const routes = declaredRoutes();
  const matchers = routes.map(routeMatcher);
  const offenders: string[] = [];

  for (const file of walk(appDir)) {
    const src = readFileSync(file, 'utf8');
    for (const m of src.matchAll(/apiPath\(\s*[`'"]([^`'"]+)/g)) {
      // Template literals interpolate an id in the last segment; compare the
      // static prefix and let the [dynamic] segment absorb the rest.
      const raw = m[1];
      const candidate = raw.replace(/\$\{[^}]*\}?.*$/, 'X');
      if (!matchers.some((re) => re.test(candidate))) {
        offenders.push(`${file.slice(webRoot.length)}: ${raw}`);
      }
    }
  }
  assert.deepEqual(
    offenders,
    [],
    `apiPath() target has no route handler under src/app/api (known: ${routes.join(', ')}): ${offenders.join(', ')}`
  );
});

test('vercel.json apex rewrites cover every API route, as deploy-transition cover', () => {
  // Not the primary defence any more (apiPath is), but a browser still running
  // the previous JS bundle after a deploy keeps calling the apex path, so the
  // apex table must stay complete rather than drift back to a partial list.
  const vercel = JSON.parse(readFileSync(join(webRoot, 'vercel.json'), 'utf8')) as {
    rewrites: { source: string; destination: string }[];
  };
  const apex = vercel.rewrites.filter((r) => r.source.startsWith('/api'));

  const covered = (route: string): boolean =>
    apex.some((r) => {
      const src = r.source.replace(/\/:path\*$/, '');
      const wildcard = r.source.endsWith('/:path*');
      const stripped = route.replace(/\/\[[^\]]+\]$/, '');
      return wildcard ? stripped.startsWith(src) : r.source === route;
    });

  const uncovered = declaredRoutes().filter((r) => !covered(r));
  assert.deepEqual(
    uncovered,
    [],
    `route handler has no apex rewrite in vercel.json — a client still on the ` +
      `previous bundle 404s after deploy: ${uncovered.join(', ')}`
  );
});

test('every apex API rewrite points at a route that exists', () => {
  const vercel = JSON.parse(readFileSync(join(webRoot, 'vercel.json'), 'utf8')) as {
    rewrites: { source: string; destination: string }[];
  };
  const offenders: string[] = [];
  for (const r of vercel.rewrites) {
    if (!r.source.startsWith('/api')) continue;
    const dest = r.destination.replace(/^\/app/, '').replace(/\/:path\*$/, '');
    // A wildcard destination is satisfied by any handler beneath it.
    const isPrefix = r.destination.endsWith('/:path*');
    const hit = isPrefix
      ? declaredRoutes().some((route) => route.startsWith(dest))
      : existsSync(join(appDir, dest, 'route.ts'));
    // /api/health is proxied straight to the backend by next.config.js rewrites
    // rather than a handler on disk.
    if (!hit && r.source !== '/api/health') offenders.push(`${r.source} -> ${r.destination}`);
  }
  assert.deepEqual(offenders, [], `vercel.json rewrite has no handler behind it: ${offenders.join(', ')}`);
});
