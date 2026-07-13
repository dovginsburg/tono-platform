const test = require('node:test');
const assert = require('node:assert/strict');

const {
  loadSupabaseDeployment,
  projectRefFromUrl,
} = require('../src/lib/supabase-deployment.cjs');

test('projectRefFromUrl accepts only canonical Supabase project URLs', () => {
  assert.equal(projectRefFromUrl('https://abcdefghijklmnopqrst.supabase.co'), 'abcdefghijklmnopqrst');
  assert.throws(() => projectRefFromUrl('https://example.com'), /canonical Supabase/);
  assert.throws(() => projectRefFromUrl('http://abcdefghijklmnopqrst.supabase.co'), /canonical Supabase/);
});

test('production deployment must use its dedicated project', () => {
  const deployment = loadSupabaseDeployment({
    TONO_DEPLOYMENT_ENV: 'production',
    TONO_SUPABASE_STAGING_PROJECT_REF: 'stagingprojectref001',
    TONO_SUPABASE_PRODUCTION_PROJECT_REF: 'productionproject001',
    NEXT_PUBLIC_SUPABASE_URL: 'https://productionproject001.supabase.co',
    NEXT_PUBLIC_SUPABASE_ANON_KEY: 'public-anon-key',
  });

  assert.equal(deployment.projectRef, 'productionproject001');
  assert.equal(deployment.url, 'https://productionproject001.supabase.co');
});

test('staging and production refs must be isolated', () => {
  assert.throws(() => loadSupabaseDeployment({
    TONO_DEPLOYMENT_ENV: 'staging',
    TONO_SUPABASE_STAGING_PROJECT_REF: 'sharedprojectref0001',
    TONO_SUPABASE_PRODUCTION_PROJECT_REF: 'sharedprojectref0001',
    NEXT_PUBLIC_SUPABASE_URL: 'https://sharedprojectref0001.supabase.co',
    NEXT_PUBLIC_SUPABASE_ANON_KEY: 'public-anon-key',
  }), /must be different/);
});

test('deployment rejects a URL for the wrong environment project', () => {
  assert.throws(() => loadSupabaseDeployment({
    TONO_DEPLOYMENT_ENV: 'staging',
    TONO_SUPABASE_STAGING_PROJECT_REF: 'stagingprojectref001',
    TONO_SUPABASE_PRODUCTION_PROJECT_REF: 'productionproject001',
    NEXT_PUBLIC_SUPABASE_URL: 'https://productionproject001.supabase.co',
    NEXT_PUBLIC_SUPABASE_ANON_KEY: 'public-anon-key',
  }), /does not match staging/);
});

test('local builds may omit Supabase, but partial configuration fails closed', () => {
  assert.equal(loadSupabaseDeployment({}, { allowUnconfigured: true }), null);
  assert.throws(() => loadSupabaseDeployment({
    NEXT_PUBLIC_SUPABASE_URL: 'https://stagingprojectref001.supabase.co',
  }, { allowUnconfigured: true }), /incomplete/);
});
