'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import {
  apiPath,
  APP_ENTRY_PATH,
  sanitizeAuthErrorCode,
  type AuthErrorCode,
} from '@/lib/auth-redirects';
import {
  EMAIL_AUTH_COPY,
  MIN_PASSWORD_LENGTH,
  looksLikeEmail,
  sanitizeEmailAuthOutcome,
  type EmailAuthOutcome,
} from '@/lib/email-auth';
import PasskeyLoginButton from '../PasskeyLoginButton';
import PasswordField from '../PasswordField';
import { appleWebSignInEnabled, APPLE_WEB_UNAVAILABLE_COPY } from '@/lib/apple-oauth-binding';
import { GIS_CLIENT_SRC } from '@/lib/google-web-auth';

// Build 114 remediation — one vocabulary for this page.
//
// The callback bounces a failed sign-in back here as a reviewed CODE (never a
// provider message, which would both leak implementation detail and, because
// those messages differ for a known and an unknown address, turn this URL into
// an account-enumeration oracle). The email flows added here speak the shared
// email-account vocabulary. Mapping the four callback codes into that one set
// means this page has a single banner and a single place where words are
// chosen, rather than two parallel copy tables that can drift apart.
const CALLBACK_CODE_TO_OUTCOME: Record<AuthErrorCode, EmailAuthOutcome> = {
  sign_in_failed: 'unknown_failure',
  link_expired: 'link_expired',
  rate_limited: 'rate_limited',
  unavailable: 'unavailable',
};

// Shown in the diagnostic footer only. Google no longer uses Supabase at all
// (direct GIS, see below); the old Supabase OAuth capability gate is gone.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';

// SEPARATE gate for the Apple button — and deliberately INDEPENDENT of the
// Supabase gate above.
//
// Apple sign-in no longer runs through Supabase. It is a direct, Tono-owned
// OAuth boundary (`/api/auth/apple/start` → Apple → `/api/auth/apple/callback`)
// under Tono's OWN Services ID (`tonoit.com`), so it works even when Supabase
// OAuth is unconfigured. The public `NEXT_PUBLIC_APPLE_WEB_SERVICES_ID` value is
// the operator's ATTESTATION that the server-side boundary (team id / key id /
// private key / redirect URI) is fully configured on this deployment; the start
// route itself independently fails closed if any secret is missing. We render
// Apple ONLY when that attested Services ID is Tono-owned — so the contaminated
// sibling id can never satisfy the gate, and a Tono user is never sent into
// another product's consent screen. Fail closed by default
// (env unset ⇒ button hidden, truthful recovery copy points at email). See
// src/lib/apple-oauth-binding.ts. The literal env reads stay inline so Next
// inlines them at build time.
const APPLE_OAUTH_ENABLED = appleWebSignInEnabled(
  process.env.NEXT_PUBLIC_APPLE_WEB_SERVICES_ID,
  process.env.NEXT_PUBLIC_APPLE_WEB_EXPECTED_SERVICES_ID,
);

// Google sign-in is a DIRECT, Tono-owned Google Identity Services (GIS) flow —
// it NEVER runs through Supabase. Supabase's Google provider is bound to a
// shared project, so it sends users to a consent screen reading "continue to
// <shared-project>.supabase.co" under a shared client id; there is deliberately
// NO fallback to it. GIS runs under Tono's OWN Web OAuth client id (consent
// screen App name "Tono"), so Google shows "Tono". The button is gated at build
// time on the public `NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID` having the Google
// Web-client shape (a stray value can't drive it); when absent, Google is hidden
// behind an honest unavailable state (email / Apple / passkeys remain) — a Tono
// user is never sent to the shared project's screen.
const GOOGLE_DIRECT_ENABLED = /^[0-9]+-[a-z0-9_]+\.apps\.googleusercontent\.com$/.test(
  (process.env.NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID ?? '').trim(),
);
const GOOGLE_UNAVAILABLE_COPY =
  'google sign-in isn’t available here yet. use email, Apple, or a passkey below.';

type Mode = 'signin' | 'create';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [promoCode, setPromoCode] = useState('');
  const [mode, setMode] = useState<Mode>('signin');
  const [busy, setBusy] = useState(false);
  // A reviewed CODE, never a message. There is no state on this page that can
  // hold provider text, so none can be rendered.
  const [outcome, setOutcome] = useState<EmailAuthOutcome | null>(null);
  // Container GIS renders its Tono-branded Google button into (direct flow only).
  const googleButtonRef = useRef<HTMLDivElement | null>(null);

  // `check_your_email` and `password_updated` are good news and must not be
  // shown in the failure banner. Splitting on the code rather than on a
  // separate boolean keeps one source of truth for what happened.
  const isGoodNews = outcome === 'check_your_email' || outcome === 'signed_in';

  // Read `?error=` AFTER mount, not in a `useState` initializer.
  //
  // This page is prerendered to static HTML at build time, so the server's
  // markup never contains the alert paragraph. Deriving the code during the
  // first client render would therefore make hydration produce an element the
  // server HTML does not have — a structural mismatch that React reports as an
  // error and recovers from by throwing away the server tree for this subtree.
  // Doing it in an effect keeps the hydration render identical to the
  // prerendered HTML and then shows the banner on the very next commit, which
  // is the one path that reliably renders the only sentence telling a person
  // why their sign-in bounced.
  useEffect(() => {
    const code = sanitizeAuthErrorCode(new URLSearchParams(window.location.search).get('error'));
    if (code) setOutcome(CALLBACK_CODE_TO_OUTCOME[code]);
  }, []);

  // Apple sign-in is a direct, Tono-owned OAuth flow. Clicking the button is a
  // top-level navigation to our own start route, which mints state+nonce, sets
  // the transaction cookies, and 302s to Apple under `client_id=tonoit.com`. It
  // never touches Supabase. `next` is carried so the callback lands the person
  // where they were headed; the route re-sanitizes it, so it cannot open-redirect.
  const startApple = () => {
    const next = new URLSearchParams(window.location.search).get('next');
    const base = apiPath('/api/auth/apple/start');
    window.location.assign(next ? `${base}?next=${encodeURIComponent(next)}` : base);
  };

  // Direct, Tono-owned Google sign-in via Google Identity Services (GIS). GIS
  // runs in the browser under Tono's OWN Web client id (consent screen "Tono")
  // and returns a signed id token to this callback. We POST it to our server
  // credential route, which forwards it to the backend (authoritative
  // verification) and sets the session cookie. No Supabase, no OAuth redirect.
  const handleGoogleCredential = async (credential: string) => {
    setOutcome(null);
    try {
      const res = await fetch(apiPath('/api/auth/google/credential'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ credential }),
      });
      const data = (await res.json().catch(() => ({}))) as { outcome?: string };
      if (data.outcome === 'signed_in') {
        // Full navigation, not a router push — the signed-in surface reads the
        // httpOnly session cookie this route just set.
        window.location.assign(APP_ENTRY_PATH);
        return;
      }
      const code = sanitizeAuthErrorCode(data.outcome ?? 'sign_in_failed') ?? 'sign_in_failed';
      setOutcome(CALLBACK_CODE_TO_OUTCOME[code]);
    } catch {
      setOutcome('unavailable');
    }
  };

  // Load GIS once and render the Tono-branded Google button, ONLY when the
  // direct boundary is attested (public Tono Web client id present). Fail closed:
  // if GIS cannot load or the id is absent, no button appears (email/Apple/
  // passkeys remain) — a Tono user is never sent to the shared project's screen.
  useEffect(() => {
    if (!GOOGLE_DIRECT_ENABLED || typeof window === 'undefined') return;
    const clientId = (process.env.NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID ?? '').trim();

    let cancelled = false;
    const render = () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const gis = (window as any).google?.accounts?.id;
      if (cancelled || !gis || !googleButtonRef.current) return;
      gis.initialize({
        client_id: clientId,
        callback: (resp: { credential?: string }) => {
          if (resp?.credential) void handleGoogleCredential(resp.credential);
        },
      });
      googleButtonRef.current.replaceChildren();
      gis.renderButton(googleButtonRef.current, {
        type: 'standard',
        theme: 'outline',
        size: 'large',
        text: 'continue_with',
        shape: 'rectangular',
        width: 320,
      });
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    if ((window as any).google?.accounts?.id) {
      render();
      return () => {
        cancelled = true;
      };
    }
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${GIS_CLIENT_SRC}"]`);
    const script = existing ?? document.createElement('script');
    if (!existing) {
      script.src = GIS_CLIENT_SRC;
      script.async = true;
      script.defer = true;
      document.head.appendChild(script);
    }
    script.addEventListener('load', render);
    return () => {
      cancelled = true;
      script.removeEventListener('load', render);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /**
   * POST one of this site's email-account routes and adopt its reviewed code.
   *
   * The route always answers 200 with an `outcome`, deliberately: letting the
   * HTTP status vary with whether an address is registered would reinstate the
   * enumeration oracle the response body is careful not to be.
   */
  const post = async (route: string, body: Record<string, string>): Promise<EmailAuthOutcome> => {
    try {
      const res = await fetch(apiPath(route), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = (await res.json()) as { outcome?: string };
      return sanitizeEmailAuthOutcome(data.outcome) ?? 'unknown_failure';
    } catch {
      return 'offline';
    }
  };

  const submitPassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!looksLikeEmail(email)) {
      setOutcome('invalid_input');
      return;
    }
    if (mode === 'create' && password.length < MIN_PASSWORD_LENGTH) {
      setOutcome('invalid_input');
      return;
    }
    setOutcome(null);
    setBusy(true);
    try {
      const result =
        mode === 'create'
          ? await post('/api/auth/email/register', { email, password, promo_code: promoCode })
          : await post('/api/auth/email/login', { email, password });
      if (result === 'signed_in') {
        // A full navigation, not a router push: the signed-in surface is
        // gated server-side and the session cookies were set by the response
        // that just landed.
        window.location.assign(APP_ENTRY_PATH);
        return;
      }
      setOutcome(result);
    } finally {
      setBusy(false);
    }
  };

  /** Ask for mail: a confirmation link again, or a recovery link. */
  const requestMail = async (route: string) => {
    if (!looksLikeEmail(email)) {
      setOutcome('invalid_input');
      return;
    }
    setOutcome(null);
    setBusy(true);
    try {
      // A rejected send is collapsed to the same confirmation a successful one
      // shows: surfacing `unknown_failure` distinctly would let this page
      // distinguish a registered address from an unknown one — the enumeration
      // oracle the 200-always backend contract is built to avoid. Only the
      // failures an outsider can already observe (throttling, an outage) stay
      // distinct.
      const reason = await post(route, { email });
      setOutcome(reason === 'unknown_failure' ? 'check_your_email' : reason);
    } finally {
      setBusy(false);
    }
  };

  // Magic-link sign-in now goes through the canonical backend
  // (/api/auth/email/magic-link → /v1/auth/email/magic-link), which sends a
  // Tono-branded link and, enforcing existing-users-only against Tono's ledger,
  // creates nothing for an unknown address. The former browser-direct Supabase
  // one-time-password path is removed: it leaked the shared tenant's
  // (non-Tono) branded sender and minted unledgered accounts. It reuses the same
  // anti-enumerating requestMail helper as reset/resend, so no browser code
  // branches on whether the address exists.
  const sendMagic = () => requestMail('/api/auth/email/magic-link');

  return (
    <div className="min-h-screen bg-tono-bg text-tono-text font-sans antialiased">
      {/* Top wordmark — the top-right dropdown lives in the root layout
          and provides full navigation. */}
      <header className="sticky top-0 z-30 bg-tono-bg/80 backdrop-blur-md border-b border-tono-border">
        <div className="max-w-[1180px] mx-auto px-6 md:px-10 py-4 flex items-center">
          <Link
            href="/"
            className="flex items-center gap-2.5 shrink-0"
            aria-label="tono — back to home"
          >
            <span
              aria-hidden="true"
              className="w-3 h-3 rounded-full bg-tono-accent shadow-[0_0_16px_var(--accent-glow)]"
            />
            <span className="text-[22px] font-bold tracking-[-0.02em] text-tono-text">tono</span>
          </Link>
        </div>
      </header>

      <main className="grid place-items-center px-6 py-12 md:py-20">
        <div className="w-full max-w-[440px] bg-tono-bg-card border border-tono-border rounded-[18px] p-7 md:p-8 shadow-[0_24px_64px_rgba(0,0,0,0.4)]">
          <h1 className="text-[28px] md:text-[32px] font-bold tracking-[-0.02em] text-tono-text leading-[1.15]">
            four ways to say it.
          </h1>
          <p className="text-tono-text-softer text-[14px] mt-2 mb-7">
            pick one, copy, send.
          </p>

          {/* OAuth buttons — Google renders whenever the Supabase provider is
              configured (fail-closed capability gate). Apple is a DIRECT,
              Tono-owned flow (not Supabase): it renders only when the operator
              has attested the server-side boundary is configured and Tono-branded
              (APPLE_OAUTH_ENABLED); otherwise it is omitted and a truthful line
              explains why, so no one is sent into a sibling product's consent
              screen. Passkeys always render with their own honest state. */}
          <div className="space-y-2.5">
            {GOOGLE_DIRECT_ENABLED ? (
              // GIS renders the Tono-branded Google button into this container.
              // There is NO Supabase fallback — Google is direct-Tono or hidden.
              <div ref={googleButtonRef} className="w-full flex justify-center min-h-[48px]" />
            ) : (
              <p
                role="note"
                className="text-[12px] text-tono-muted leading-[1.5] px-1 py-1"
              >
                {GOOGLE_UNAVAILABLE_COPY}
              </p>
            )}
            {APPLE_OAUTH_ENABLED ? (
              <button
                type="button"
                onClick={startApple}
                className="w-full inline-flex items-center justify-center gap-3 px-5 py-3 rounded-[12px] bg-tono-bg-elev hover:bg-tono-bg-card text-tono-text border border-tono-border hover:border-tono-border-strong font-semibold text-[14px] transition min-h-[48px]"
                aria-label="Continue with Apple"
              >
                <AppleIcon /> continue with apple
              </button>
            ) : (
              <p
                role="note"
                className="text-[12px] text-tono-muted leading-[1.5] px-1 py-1"
              >
                {APPLE_WEB_UNAVAILABLE_COPY}
              </p>
            )}
            <PasskeyLoginButton />
          </div>

          <Divider />

          {/* Email + password — the same account the apps use. */}
          <div
            className="grid grid-cols-2 gap-1 p-1 mb-4 bg-tono-bg-elev border border-tono-border rounded-[12px]"
            role="tablist"
            aria-label="email account"
          >
            {(['signin', 'create'] as Mode[]).map((m) => (
              <button
                key={m}
                type="button"
                role="tab"
                aria-selected={mode === m}
                onClick={() => {
                  setMode(m);
                  setOutcome(null);
                }}
                className={`px-3 py-2 rounded-[9px] text-[13px] font-semibold transition min-h-[40px] ${
                  mode === m
                    ? 'bg-tono-bg-card text-tono-text border border-tono-border-strong'
                    : 'text-tono-text-softer hover:text-tono-text'
                }`}
              >
                {m === 'signin' ? 'sign in' : 'create account'}
              </button>
            ))}
          </div>

          <form onSubmit={submitPassword} className="space-y-3">
            <div>
              <label
                htmlFor="email"
                className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
              >
                email
              </label>
              <input
                id="email"
                type="email"
                required
                placeholder="you@work.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted"
                autoComplete="email"
              />
            </div>
            {mode === 'create' ? (
              <div>
                <label
                  htmlFor="promo-code"
                  className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
                >
                  promo code <span className="normal-case font-normal">(optional)</span>
                </label>
                <input
                  id="promo-code"
                  type="text"
                  value={promoCode}
                  onChange={(e) => setPromoCode(e.target.value)}
                  placeholder="applied after email verification"
                  className="w-full bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted"
                  autoComplete="off"
                />
              </div>
            ) : null}
            <div>
              <label
                htmlFor="password"
                className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
              >
                password
              </label>
              <PasswordField
                id="password"
                required
                minLength={mode === 'create' ? MIN_PASSWORD_LENGTH : undefined}
                placeholder={
                  mode === 'create' ? `at least ${MIN_PASSWORD_LENGTH} characters` : undefined
                }
                value={password}
                onChange={setPassword}
                autoComplete={mode === 'create' ? 'new-password' : 'current-password'}
              />
            </div>
            <button
              type="submit"
              disabled={busy || !email || !password}
              className="w-full inline-flex items-center justify-center px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:cursor-not-allowed text-white font-semibold text-[14px] transition min-h-[48px]"
            >
              {busy ? 'one moment…' : mode === 'create' ? 'create account' : 'sign in'}
            </button>
          </form>

          {/* The three things a person needs when the password path stalls.
              Every one of them is an affordance the web did not have, and two
              of them are what the mobile apps tell people to come here for. */}
          <div className="mt-4 flex flex-wrap gap-x-4 gap-y-2 text-[12px] text-tono-text-softer">
            <button
              type="button"
              onClick={() => requestMail('/api/auth/email/reset')}
              disabled={busy}
              className="underline hover:text-tono-text disabled:opacity-60 transition"
            >
              forgot your password?
            </button>
            <button
              type="button"
              onClick={() => requestMail('/api/auth/email/resend')}
              disabled={busy}
              className="underline hover:text-tono-text disabled:opacity-60 transition"
            >
              resend confirmation
            </button>
            <button
              type="button"
              onClick={sendMagic}
              disabled={busy}
              className="underline hover:text-tono-text disabled:opacity-60 transition"
            >
              email me a link instead
            </button>
          </div>

          {outcome &&
            (isGoodNews ? (
              <div
                role="status"
                className="mt-4 bg-tono-bg-elev border border-tono-border rounded-[12px] p-4 text-[14px] text-tono-text-soft leading-[1.55]"
              >
                <strong className="text-tono-text">{EMAIL_AUTH_COPY[outcome]}</strong>{' '}
                open it on this device to finish.
              </div>
            ) : (
              <p
                role="alert"
                className="mt-4 p-3 bg-[rgba(239,68,68,0.08)] border border-[rgba(239,68,68,0.3)] rounded-[12px] text-[#FCA5A5] text-[13px] leading-[1.5]"
              >
                {EMAIL_AUTH_COPY[outcome]}
              </p>
            ))}

          <p className="mt-8 text-[12px] text-tono-muted text-center">
            by signing in, you agree tono holds your drafts. nothing else.
          </p>

          {process.env.NODE_ENV !== 'production' && (
            <p className="mt-4 text-[10px] text-tono-muted text-center opacity-60 break-all">
              supabase: {SUPABASE_URL}
            </p>
          )}
        </div>
      </main>
    </div>
  );
}

function Divider() {
  return (
    <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-3 my-6">
      <div className="h-px bg-tono-border" />
      <span className="text-[11px] text-tono-muted uppercase tracking-wider font-semibold">
        or
      </span>
      <div className="h-px bg-tono-border" />
    </div>
  );
}

function GoogleIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden>
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.3 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34 6.1 29.3 4 24 4 13 4 4 13 4 24s9 20 20 20 20-9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 16 19 13 24 13c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.6 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.1 35.1 26.7 36 24 36c-5.3 0-9.7-3.3-11.3-7.9l-6.5 5C9.4 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.1-4.1 5.5l6.2 5.2c-.4.4 6.6-4.8 6.6-14.7 0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  );
}

// Canonical Apple logo glyph.
//
// The previous path spilled outside its `0 0 24 24` viewBox — its bounding box
// ran to x=-4.74 on the left and y=25.06 at the bottom — so the SVG's default
// `overflow:hidden` viewport clipped the left flank and base of the apple,
// rendering as a malformed "bag/mug" rather than the Apple mark. This path is
// the standard Apple glyph and sits wholly inside the viewBox (x≈2.8–19.6,
// y≈3–21.3), centered with margin on every side. `preserveAspectRatio` is left
// explicit and the square viewBox is drawn into a square 16×16 viewport, so the
// mark scales uniformly and keeps its native ratio on every viewport. The icon
// stays `aria-hidden`; the button's own `aria-label="Continue with Apple"`
// carries the accessible name.
function AppleIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      preserveAspectRatio="xMidYMid meet"
      fill="currentColor"
      aria-hidden
    >
      <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
    </svg>
  );
}
