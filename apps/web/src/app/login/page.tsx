'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { createClient } from '@/lib/supabase-client';
import {
  apiPath,
  APP_ENTRY_PATH,
  buildAuthCallbackUrl,
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

/**
 * Classify a client-side auth failure by SHAPE.
 *
 * Reads only the status the provider client exposes. Sending a link is
 * deliberately answered the same way whether or not the address is registered,
 * so a failure here can never be the thing that reveals it.
 */
function classifyAuthFailure(error: unknown): EmailAuthOutcome {
  const status = (error as { status?: number } | null)?.status;
  if (status === 429) return 'rate_limited';
  if (typeof status === 'number' && status >= 500) return 'unavailable';
  return 'unknown_failure';
}

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';

// Capability gate for the Apple/Google OAuth buttons.
//
// Those buttons can only complete a sign-in through a configured Supabase
// project. When either public value is absent at build time, the provider
// client cannot start an OAuth flow, so rendering the buttons would give a
// person a control that fails the instant they click it. We fail closed and
// omit them entirely — mirroring how passkeys surface an honest "not configured
// here yet" state rather than a dead button. Email/password + passkeys remain.
const OAUTH_CONFIGURED = Boolean(SUPABASE_URL && SUPABASE_ANON_KEY);

// build a basePath-aware redirect URI:
//   on tonoit.com, callback URL is https://tonoit.com/app/auth/callback
//   on localhost, callback URL is http://localhost:3000/app/auth/callback
function buildRedirectTo(): string {
  if (typeof window === 'undefined') return '';
  const base = buildAuthCallbackUrl(window.location.origin, {
    NODE_ENV: process.env.NODE_ENV,
    NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
  });
  // Preserve where the visitor was headed (e.g. /app/pricing to finish
  // checkout). Supabase appends its own ?code=… to redirect_to, so the
  // callback receives both params; it re-validates `next` with sanitizeNextPath
  // before ever redirecting, so a hostile value can't become an open redirect.
  const next = new URLSearchParams(window.location.search).get('next');
  if (!next) return base;
  try {
    const url = new URL(base);
    url.searchParams.set('next', next);
    return url.toString();
  } catch {
    return base;
  }
}

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

  const oauth = async (provider: 'apple' | 'google') => {
    setOutcome(null);
    const supabase = createClient();
    const { error: err } = await supabase.auth.signInWithOAuth({
      provider,
      options: {
        redirectTo: buildRedirectTo(),
        // Sherlock's runbook #4 — Supabase dashboard needs these URLs whitelisted.
        // (Dov does dashboard config; this just states intent.)
        scopes: provider === 'google' ? 'email profile' : undefined,
      },
    });
    if (err) setOutcome(classifyAuthFailure(err));
  };

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
      setOutcome(await post(route, { email }));
    } finally {
      setBusy(false);
    }
  };

  const sendMagic = async () => {
    if (!looksLikeEmail(email)) {
      setOutcome('invalid_input');
      return;
    }
    setOutcome(null);
    setBusy(true);
    try {
      const supabase = createClient();
      const { error: err } = await supabase.auth.signInWithOtp({
        email,
        options: {
          emailRedirectTo: buildRedirectTo(),
          shouldCreateUser: true,
        },
      });
      // Anti-enumerating: a rejected send shows the confirmation anyway unless
      // the failure is one an outsider can already observe (throttling, outage).
      // Otherwise "we couldn't send that" for an unregistered address and
      // "check your inbox" for a registered one would answer the only question
      // an attacker has.
      if (err) {
        const reason = classifyAuthFailure(err);
        setOutcome(reason === 'unknown_failure' ? 'check_your_email' : reason);
      } else {
        setOutcome('check_your_email');
      }
    } finally {
      setBusy(false);
    }
  };

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

          {/* OAuth buttons — rendered only when the provider is configured
              (fail-closed capability gate); passkeys always render with their
              own honest not-configured state. */}
          <div className="space-y-2.5">
            {OAUTH_CONFIGURED ? (
              <>
                <button
                  type="button"
                  onClick={() => oauth('google')}
                  className="w-full inline-flex items-center justify-center gap-3 px-5 py-3 rounded-[12px] bg-tono-bg-elev hover:bg-tono-bg-card text-tono-text border border-tono-border hover:border-tono-border-strong font-semibold text-[14px] transition min-h-[48px]"
                  aria-label="Continue with Google"
                >
                  <GoogleIcon /> continue with google
                </button>
                <button
                  type="button"
                  onClick={() => oauth('apple')}
                  className="w-full inline-flex items-center justify-center gap-3 px-5 py-3 rounded-[12px] bg-tono-bg-elev hover:bg-tono-bg-card text-tono-text border border-tono-border hover:border-tono-border-strong font-semibold text-[14px] transition min-h-[48px]"
                  aria-label="Continue with Apple"
                >
                  <AppleIcon /> continue with apple
                </button>
              </>
            ) : null}
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

function AppleIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M16.365 1.43c0 1.14-.43 2.21-1.13 3-.71.79-1.85 1.4-2.99 1.32-.13-1.13.43-2.31 1.13-3.07.79-.85 2.07-1.45 2.99-1.25zM21 17.21c-.6 1.39-1.3 2.74-2.2 4.01-1.2 1.69-2.91 3.79-5.02 3.81-1.88.02-2.36-1.21-4.92-1.2-2.55.02-3.1 1.23-4.97 1.21-2.11-.02-3.72-1.93-4.92-3.62-3.36-4.74-3.71-10.3-1.64-13.26 1.47-2.1 3.79-3.33 5.97-3.33 2.21 0 3.6 1.21 5.43 1.21 1.78 0 2.86-1.21 5.41-1.21 1.94 0 4.01 1.06 5.47 2.88-4.81 2.64-4.03 9.5 1.39 11.5z" />
    </svg>
  );
}
