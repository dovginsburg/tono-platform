export const BASE_PATH = '/app';
export const APP_ENTRY_PATH = `${BASE_PATH}/app`;
export const LOGIN_PATH = `${BASE_PATH}/login`;
export const AUTH_CALLBACK_PATH = `${BASE_PATH}/auth/callback`;

const CANONICAL_ORIGIN = 'https://tonoit.com';

type RedirectEnvironment = {
  NODE_ENV?: string;
  NEXT_PUBLIC_SITE_URL?: string;
  VERCEL_ENV?: string;
  VERCEL_URL?: string;
};

function parseOrigin(value: string | undefined): URL | null {
  if (!value) return null;

  try {
    const url = new URL(value.includes('://') ? value : `https://${value}`);
    if (url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
      return null;
    }
    return url;
  } catch {
    return null;
  }
}

function isAllowedOrigin(url: URL, env: RedirectEnvironment): boolean {
  if (url.protocol === 'https:' && (url.hostname === 'tonoit.com' || url.hostname.endsWith('.tonoit.com'))) {
    return true;
  }

  if (env.NODE_ENV !== 'production' && url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname)) {
    return true;
  }

  const vercelUrl = parseOrigin(env.VERCEL_URL);
  return (
    env.VERCEL_ENV === 'preview' &&
    url.protocol === 'https:' &&
    url.hostname.endsWith('.vercel.app') &&
    vercelUrl?.hostname === url.hostname
  );
}

export function resolvePublicOrigin(
  candidateOrigin?: string,
  env: RedirectEnvironment = process.env
): string {
  for (const candidate of [candidateOrigin, env.NEXT_PUBLIC_SITE_URL]) {
    const parsed = parseOrigin(candidate);
    if (parsed && isAllowedOrigin(parsed, env)) return parsed.origin;
  }

  if (env.VERCEL_ENV === 'preview') {
    const preview = parseOrigin(env.VERCEL_URL);
    if (preview && isAllowedOrigin(preview, env)) return preview.origin;
  }

  if (env.NODE_ENV !== 'production') return 'http://localhost:3000';
  return CANONICAL_ORIGIN;
}

export function sanitizeNextPath(value: string | null | undefined): string {
  if (!value || /[\\\u0000-\u001f\u007f]/.test(value) || value.startsWith('//')) {
    return APP_ENTRY_PATH;
  }

  try {
    const parsed = new URL(value, CANONICAL_ORIGIN);
    const isAppEntry =
      parsed.origin === CANONICAL_ORIGIN &&
      (parsed.pathname === APP_ENTRY_PATH || parsed.pathname.startsWith(`${APP_ENTRY_PATH}/`));

    if (!isAppEntry) return APP_ENTRY_PATH;
    return `${parsed.pathname}${parsed.search}${parsed.hash}`;
  } catch {
    return APP_ENTRY_PATH;
  }
}

export function buildLoginRedirect(
  nextPath: string | null | undefined = APP_ENTRY_PATH,
  env: RedirectEnvironment = process.env,
  error?: string
): string {
  const login = new URL(LOGIN_PATH, resolvePublicOrigin(undefined, env));
  login.searchParams.set('next', sanitizeNextPath(nextPath));
  if (error) login.searchParams.set('error', error);
  return login.toString();
}

export function buildAppRedirect(
  nextPath: string | null | undefined,
  env: RedirectEnvironment = process.env
): string {
  return new URL(sanitizeNextPath(nextPath), resolvePublicOrigin(undefined, env)).toString();
}

export function buildAuthCallbackUrl(
  candidateOrigin?: string,
  env: RedirectEnvironment = process.env
): string {
  return new URL(AUTH_CALLBACK_PATH, resolvePublicOrigin(candidateOrigin, env)).toString();
}
