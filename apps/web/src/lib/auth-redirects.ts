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

function isCanonicalOrigin(url: URL, env: RedirectEnvironment): boolean {
  if (url.protocol === 'https:' && (url.hostname === 'tonoit.com' || url.hostname.endsWith('.tonoit.com'))) {
    return true;
  }

  return (
    env.NODE_ENV !== 'production' &&
    url.protocol === 'http:' &&
    ['localhost', '127.0.0.1'].includes(url.hostname)
  );
}

// This deployment's own preview host, and only when an operator has named it
// deliberately. Never inferred — see resolvePublicOrigin.
function isApprovedPreviewOrigin(url: URL, env: RedirectEnvironment): boolean {
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
  // Every origin returned here becomes an externally shareable absolute URL —
  // the Stripe success/cancel and billing-portal return URLs, and the
  // magic-link/OAuth callback Supabase mails to the user. A preview deployment
  // is a per-deployment *.vercel.app host that sits behind deployment
  // protection and still runs this app's auth middleware, so any such link that
  // leaves the browser strands its recipient on a preview auth wall instead of
  // tonoit.com. A preview host therefore has exactly one way in: an operator
  // naming it in NEXT_PUBLIC_SITE_URL for staging QA
  // (docs/operations/web-protected-redirect-staging.md).

  // Caller-supplied — window.location.origin on the login page. This is
  // whatever host the visitor happens to be on, so it is honoured only when
  // already canonical; it can never introduce a preview host.
  const candidate = parseOrigin(candidateOrigin);
  if (candidate && isCanonicalOrigin(candidate, env)) return candidate.origin;

  // Operator-configured, and the only accepted source of an approved preview
  // origin. Note there is no fall-back to VERCEL_URL: a preview never adopts
  // its own host by inference.
  const configured = parseOrigin(env.NEXT_PUBLIC_SITE_URL);
  if (configured && (isCanonicalOrigin(configured, env) || isApprovedPreviewOrigin(configured, env))) {
    return configured.origin;
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

    // Same-origin only — `next` must never become an open redirect.
    if (parsed.origin !== CANONICAL_ORIGIN) return APP_ENTRY_PATH;

    const pathname = parsed.pathname;

    // Must land inside the app's basePath. This intentionally covers the whole
    // signed-in surface a visitor may have been trying to reach before login —
    // /app/pricing (so they can finish checkout), /app/account, the editor —
    // not just the editor entry. Anything outside /app falls back to the editor.
    const withinApp = pathname === BASE_PATH || pathname.startsWith(`${BASE_PATH}/`);
    if (!withinApp) return APP_ENTRY_PATH;

    // Never bounce back into an auth route — that would loop the sign-in flow.
    if (
      pathname === LOGIN_PATH ||
      pathname.startsWith(`${LOGIN_PATH}/`) ||
      pathname.startsWith(`${BASE_PATH}/auth`)
    ) {
      return APP_ENTRY_PATH;
    }

    return `${pathname}${parsed.search}${parsed.hash}`;
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
