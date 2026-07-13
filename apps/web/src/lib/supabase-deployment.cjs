'use strict';

const CANONICAL_SUPABASE_URL = /^https:\/\/([a-z0-9]{20})\.supabase\.co\/?$/;

function projectRefFromUrl(value) {
  const match = CANONICAL_SUPABASE_URL.exec(value || '');
  if (!match) {
    throw new Error('NEXT_PUBLIC_SUPABASE_URL must be a canonical Supabase project URL');
  }
  return match[1];
}

function loadSupabaseDeployment(env, { allowUnconfigured = false } = {}) {
  const names = [
    'TONO_DEPLOYMENT_ENV',
    'TONO_SUPABASE_STAGING_PROJECT_REF',
    'TONO_SUPABASE_PRODUCTION_PROJECT_REF',
    'NEXT_PUBLIC_SUPABASE_URL',
    'NEXT_PUBLIC_SUPABASE_ANON_KEY',
  ];
  const present = names.filter((name) => Boolean(env[name]));

  if (present.length === 0 && allowUnconfigured) return null;
  if (present.length !== names.length) {
    throw new Error(`Supabase deployment configuration is incomplete; required: ${names.join(', ')}`);
  }

  const deploymentEnv = env.TONO_DEPLOYMENT_ENV;
  if (!['staging', 'production'].includes(deploymentEnv)) {
    throw new Error('TONO_DEPLOYMENT_ENV must be staging or production');
  }

  const stagingRef = env.TONO_SUPABASE_STAGING_PROJECT_REF;
  const productionRef = env.TONO_SUPABASE_PRODUCTION_PROJECT_REF;
  if (stagingRef === productionRef) {
    throw new Error('Tono staging and production Supabase project refs must be different');
  }

  const projectRef = projectRefFromUrl(env.NEXT_PUBLIC_SUPABASE_URL);
  const expectedRef = deploymentEnv === 'production' ? productionRef : stagingRef;
  if (projectRef !== expectedRef) {
    throw new Error(`NEXT_PUBLIC_SUPABASE_URL project ${projectRef} does not match ${deploymentEnv} project ${expectedRef}`);
  }

  return Object.freeze({
    environment: deploymentEnv,
    projectRef,
    url: `https://${projectRef}.supabase.co`,
    anonKey: env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  });
}

module.exports = { loadSupabaseDeployment, projectRefFromUrl };
