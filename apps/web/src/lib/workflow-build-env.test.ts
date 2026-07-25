import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadSupabaseDeployment } from './supabase-deployment.cjs';

// Guard: every CI/CD workflow step that runs `npm run build` must supply an env
// that next.config.js can actually load.
//
// next.config.js calls loadSupabaseDeployment(env, { allowUnconfigured: true }),
// which accepts exactly two shapes — NOTHING configured (returns null) or ALL
// FIVE names configured. A PARTIAL set throws, and it additionally requires
// NEXT_PUBLIC_SUPABASE_URL to be a canonical https://<20-char>.supabase.co URL.
//
// `deploy-staging.yml` supplied only NEXT_PUBLIC_SUPABASE_URL (as
// `https://example.invalid`) and NEXT_PUBLIC_SUPABASE_ANON_KEY. That is a
// partial set with a non-canonical URL, so "Build web artifact" threw
// "Supabase deployment configuration is incomplete" and the canonical staging
// deploy aborted before reaching any deploy step — the release path could not
// run at all. Reproduced locally against this exact contract before the fix.

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..', '..');
const workflowsDir = join(repoRoot, '.github', 'workflows');

/**
 * Extract the `env:` mapping that immediately precedes/accompanies a step whose
 * `run:` invokes `npm run build`. Deliberately a small hand parser: adding a
 * YAML dependency to ship one guard is not worth it.
 */
function buildStepEnvs(workflow: string): Record<string, string>[] {
  const lines = readFileSync(join(workflowsDir, workflow), 'utf8').split('\n');
  const out: Record<string, string>[] = [];

  for (let i = 0; i < lines.length; i++) {
    // Start of a step (list item) — collect the whole step block by indentation.
    if (!/^\s*- (name|run|uses):/.test(lines[i])) continue;
    const indent = lines[i].search(/\S/);
    const block: string[] = [lines[i]];
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === '') { block.push(l); continue; }
      const ind = l.search(/\S/);
      if (ind <= indent && /^\s*- /.test(l)) break;   // next step
      if (ind < indent) break;                         // dedented out of the step
      block.push(l);
    }
    const text = block.join('\n');
    if (!/npm run build/.test(text)) continue;

    const env: Record<string, string> = {};
    const envIdx = block.findIndex((l) => /^\s*env:\s*$/.test(l));
    if (envIdx !== -1) {
      const envIndent = block[envIdx].search(/\S/);
      for (let k = envIdx + 1; k < block.length; k++) {
        const l = block[k];
        if (l.trim() === '') continue;
        const ind = l.search(/\S/);
        if (ind <= envIndent) break;
        const m = /^\s*([A-Z0-9_]+):\s*(.*)$/.exec(l);
        if (m) env[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '');
      }
    }
    out.push(env);
  }
  return out;
}

const WORKFLOWS = ['ci.yml', 'deploy-staging.yml'];

test('the parser actually finds a build step in each workflow', () => {
  for (const wf of WORKFLOWS) {
    const envs = buildStepEnvs(wf);
    assert.ok(
      envs.length > 0,
      `${wf}: no \`npm run build\` step found — the guard below would vacuously pass`
    );
  }
});

for (const wf of WORKFLOWS) {
  test(`${wf}: every npm-run-build step env satisfies next.config.js`, () => {
    for (const env of buildStepEnvs(wf)) {
      // GitHub expressions (${{ ... }}) resolve at runtime; drop them so the
      // check reflects only statically-declared values.
      const statik = Object.fromEntries(
        Object.entries(env).filter(([, v]) => !v.includes('${{'))
      );
      assert.doesNotThrow(
        () => loadSupabaseDeployment(statik, { allowUnconfigured: true }),
        `${wf} declares a partial/invalid Supabase env for \`npm run build\`; ` +
          `next.config.js will throw and the job aborts. Supply all five names ` +
          `with a canonical https://<20-char-ref>.supabase.co URL, or none at all. ` +
          `Declared: ${JSON.stringify(statik)}`
      );
    }
  });
}

test('deploy-staging builds as a staging deployment, not production', () => {
  const envs = buildStepEnvs('deploy-staging.yml');
  const resolved = envs
    .map((e) => loadSupabaseDeployment(e, { allowUnconfigured: true }))
    .filter(Boolean) as { environment: string }[];
  assert.ok(resolved.length > 0, 'deploy-staging must configure a Supabase deployment');
  for (const r of resolved) {
    assert.equal(
      r.environment,
      'staging',
      'the staging deploy workflow must never build with TONO_DEPLOYMENT_ENV=production'
    );
  }
});

test('no workflow build step hardcodes a real Supabase project ref', () => {
  // The two production/staging refs live in Vercel env vars, never in the repo.
  const realRefPrefixes = ['bndbgpqbpzukrbhquz', 'kmqaxsydahnftpqzkq'];
  for (const wf of WORKFLOWS) {
    const raw = readFileSync(join(workflowsDir, wf), 'utf8');
    for (const ref of realRefPrefixes) {
      assert.ok(
        !raw.includes(ref),
        `${wf} hardcodes what looks like a real Supabase project ref (${ref}…)`
      );
    }
  }
});
