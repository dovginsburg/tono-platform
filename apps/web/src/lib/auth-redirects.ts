export const BASE_PATH = '/app';
export const APP_ENTRY_PATH = `${BASE_PATH}/app`;
export const LOGIN_PATH = `${BASE_PATH}/login`;
export const AUTH_CALLBACK_PATH = `${BASE_PATH}/auth/callback`;
export const AUTH_RESET_PATH = `${BASE_PATH}/auth/reset`;

const CANONICAL_ORIGIN = 'https://tonoit.com';

/**
 * Absolute, basePath-qualified path for one of this app's route handlers.
 *
 * next.config.js sets `basePath: '/app'`, so every handler under
 * `src/app/api/**\/route.ts` is served at `/app/api/...`. Next rewrites
 * `<Link href>` for basePath, but it does NOT rewrite `fetch()`, raw
 * `<form action>`, or `window.location` — those resolve against the document
 * ORIGIN, so a bare `fetch('/api/portal')` requests `https://tonoit.com/api/portal`.
 *
 * Apex `/api/*` only resolves for the handful of paths hand-listed in
 * vercel.json's rewrite table, so bare paths silently 404 for anything not on
 * that list. Route this through here instead of depending on that list: the
 * argument mirrors the handler's folder path, so `apiPath('/api/portal')`
 * (= `src/app/api/portal/route.ts`) always hits the real handler.
 *
 * Guarded by `src/lib/api-path.test.ts`, which fails the build if a client
 * component reintroduces a bare `/api/...` fetch.
 */
export function apiPath(route: string): string {
  const normalized = route.startsWith('/') ? route : `/${route}`;
  return `${BASE_PATH}${normalized}`;
}

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

// Build 114 — the closed set of reasons a sign-in can bounce back to /login.
//
// This used to be a free `error` string, and the caller passed the auth
// provider's own message straight into the URL, where the login page rendered
// it. Two problems, both real:
//
//   * the provider's messages differ for a known and an unknown address, so the
//     URL became an account-enumeration oracle;
//   * the text is provider detail — it has named hosts, projects and internal
//     reasons — and a person cannot act on any of it.
//
// A closed set of CODES fixes both. The page owns the words; the code only says
// which reviewed sentence to show, and an unrecognised value is dropped rather
// than displayed.
export const AUTH_ERROR_CODES = [
  'sign_in_failed',
  'link_expired',
  'rate_limited',
  'unavailable',
] as const;

export type AuthErrorCode = (typeof AUTH_ERROR_CODES)[number];

/** Keep only a reviewed code. Anything else becomes null — silence beats noise. */
export function sanitizeAuthErrorCode(raw: string | null | undefined): AuthErrorCode | null {
  return AUTH_ERROR_CODES.includes(raw as AuthErrorCode) ? (raw as AuthErrorCode) : null;
}

export function buildLoginRedirect(
  nextPath: string | null | undefined = APP_ENTRY_PATH,
  env: RedirectEnvironment = process.env,
  error?: AuthErrorCode | null
): string {
  const login = new URL(LOGIN_PATH, resolvePublicOrigin(undefined, env));
  login.searchParams.set('next', sanitizeNextPath(nextPath));
  const code = sanitizeAuthErrorCode(error);
  if (code) login.searchParams.set('error', code);
  return login.toString();
}

// Build 114 remediation — is this callback completing a password RECOVERY?
//
// `flow=recovery` is ours: the backend appends it to the redirect target when
// it asks the provider to mail a recovery link, so the signal does not depend
// on provider link formatting. `type=recovery` is the provider's own marker,
// honoured as well because it costs nothing and covers a link minted before
// this shipped.
//
// It matters that this is a marker and not a guess. A recovery link that is
// merely SIGNED IN and dropped into the app is exactly the dead end being
// fixed: the person was promised a screen where they choose a new password and
// never saw one.
export function isRecoveryCallback(params: URLSearchParams): boolean {
  return params.get('flow') === 'recovery' || params.get('type') === 'recovery';
}

export function buildResetRedirect(env: RedirectEnvironment = process.env): string {
  return new URL(AUTH_RESET_PATH, resolvePublicOrigin(undefined, env)).toString();
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
