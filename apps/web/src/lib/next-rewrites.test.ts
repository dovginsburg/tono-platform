import assert from 'node:assert/strict';
import test from 'node:test';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Guard against two live definitions of the same path.
//
// next.config.js returns rewrites as an ARRAY, which Next places in the
// `afterFiles` phase — consulted only after filesystem routes. A rewrite whose
// source collides with a handler under src/app/api therefore never fires, but
// still reads as that path's definition.
//
// That is exactly what `/api/checkout` and `/api/analyze` were: declared here
// as straight proxies to api.tonoit.com while the real traffic went to the
// route handlers, which additionally enforce the same-origin CSRF guard and
// exchange the httpOnly `tono_api_token` cookie for a bearer. Anyone "fixing"
// the dead rewrite by promoting it to `beforeFiles` would have silently
// removed both protections.
//
// Rule: next.config.js may only rewrite paths that have NO handler behind them.

const here = dirname(fileURLToPath(import.meta.url));
const appDir = join(here, '..', 'app');
const webRoot = join(here, '..', '..');

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}

/** App-relative route paths, e.g. '/api/portal', '/sitemap.xml'. */
function declaredRoutes(): string[] {
  return walk(appDir)
    .filter((f) => f.endsWith('/route.ts'))
    .map((f) => f.slice(appDir.length).replace(/\/route\.ts$/, ''));
}

/** Rewrite sources declared in next.config.js, read as text (no Next import). */
function declaredRewriteSources(): string[] {
  const src = readFileSync(join(webRoot, 'next.config.js'), 'utf8');
  const body = src.slice(src.indexOf('async rewrites()'), src.indexOf('redirects:'));
  return [...body.matchAll(/source:\s*'([^']+)'/g)].map((m) => m[1]);
}

// A wildcard rewrite may legitimately span a path that one handler also serves,
// as long as the overlap is deliberate and the handler is meant to win. Each
// such case is listed here with its reason; anything NOT listed is a defect.
const ACKNOWLEDGED_OVERLAPS: Record<string, string> = {
  '/auth/:path*':
    "Supabase proxy. /auth/callback is deliberately ours — the app exchanges the " +
    "OAuth code and mints the backend bearer there — and wins because rewrites " +
    'are afterFiles. Promoting this to beforeFiles would proxy the callback to ' +
    'Supabase and break sign-in entirely.',
};

test('no next.config.js rewrite shadows a route handler', () => {
  const routes = new Set(declaredRoutes());
  const offenders = declaredRewriteSources().filter((source) => {
    if (source in ACKNOWLEDGED_OVERLAPS) return false;
    const base = source.replace(/\/:path\*$/, '');
    if (source.endsWith('/:path*')) {
      return [...routes].some((r) => r === base || r.startsWith(`${base}/`));
    }
    return routes.has(source);
  });

  assert.deepEqual(
    offenders,
    [],
    `next.config.js rewrites a path that a route handler already serves. The ` +
      `rewrite is in the afterFiles phase so it never fires, and promoting it ` +
      `would bypass the handler's CSRF guard and cookie->bearer exchange. ` +
      `If the overlap is intentional, add it to ACKNOWLEDGED_OVERLAPS with a ` +
      `reason: ${offenders.join(', ')}`
  );
});

test('every acknowledged overlap still corresponds to a real rewrite', () => {
  // Keeps the allowlist from outliving the config it excuses.
  const sources = new Set(declaredRewriteSources());
  const stale = Object.keys(ACKNOWLEDGED_OVERLAPS).filter((s) => !sources.has(s));
  assert.deepEqual(
    stale,
    [],
    `ACKNOWLEDGED_OVERLAPS lists a rewrite next.config.js no longer declares: ${stale.join(', ')}`
  );
});

test('no next.config.js rewrite is a self-referential no-op', () => {
  // basePath is applied to source AND destination, so `/sitemap.xml ->
  // /sitemap.xml` compiles to `/app/sitemap.xml -> /app/sitemap.xml`.
  const src = readFileSync(join(webRoot, 'next.config.js'), 'utf8');
  const body = src.slice(src.indexOf('async rewrites()'), src.indexOf('redirects:'));
  const offenders: string[] = [];
  for (const m of body.matchAll(/source:\s*'([^']+)',\s*destination:\s*'([^']+)'/g)) {
    if (m[1] === m[2]) offenders.push(m[1]);
  }
  assert.deepEqual(offenders, [], `self-referential rewrite: ${offenders.join(', ')}`);
});

test('apex SEO surface is still served by vercel.json', () => {
  // Removing the no-op next.config entries must not orphan /sitemap.xml or
  // /robots.txt at the apex — vercel.json is what actually maps them.
  const vercel = JSON.parse(readFileSync(join(webRoot, 'vercel.json'), 'utf8')) as {
    rewrites: { source: string; destination: string }[];
  };
  const routes = declaredRoutes();
  for (const path of ['/sitemap.xml', '/robots.txt']) {
    const rule = vercel.rewrites.find((r) => r.source === path);
    assert.ok(rule, `vercel.json must map apex ${path}`);
    const target = rule!.destination.replace(/^\/app/, '');
    assert.ok(
      routes.includes(target),
      `vercel.json maps ${path} -> ${rule!.destination}, but no handler serves ${target}`
    );
  }
});
