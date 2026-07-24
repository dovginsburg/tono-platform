'use client';

import { useState } from 'react';
import Link from 'next/link';
import { createClient } from '@/lib/supabase-client';
import { buildAuthCallbackUrl } from '@/lib/auth-redirects';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';

// build a basePath-aware redirect URI:
//   on tonoit.com, callback URL is https://tonoit.com/app/auth/callback
//   on localhost, callback URL is http://localhost:3000/app/auth/callback
function buildRedirectTo(): string {
  if (typeof window === 'undefined') return '';
  return buildAuthCallbackUrl(window.location.origin, {
    NODE_ENV: process.env.NODE_ENV,
    NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
  });
}

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [sending, setSending] = useState(false);
  const [magicSent, setMagicSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const oauth = async (provider: 'apple' | 'google') => {
    setError(null);
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
    if (err) setError(err.message);
  };

  const sendMagic = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setSending(true);
    try {
      const supabase = createClient();
      const { error: err } = await supabase.auth.signInWithOtp({
        email,
        options: {
          emailRedirectTo: buildRedirectTo(),
          shouldCreateUser: true,
        },
      });
      if (err) setError(err.message);
      else setMagicSent(true);
    } finally {
      setSending(false);
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

          {/* OAuth buttons */}
          <div className="space-y-2.5">
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
          </div>

          <Divider />

          {/* Magic link */}
          {magicSent ? (
            <div
              role="status"
              className="bg-tono-bg-elev border border-tono-border rounded-[12px] p-4 text-[14px] text-tono-text-soft leading-[1.55]"
            >
              <strong className="text-tono-text">check your inbox.</strong> a magic link is
              on its way. open it on this device to finish signing in.
            </div>
          ) : (
            <form onSubmit={sendMagic}>
              <label
                htmlFor="email"
                className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
              >
                sign in with email
              </label>
              <div className="flex gap-2">
                <input
                  id="email"
                  type="email"
                  required
                  placeholder="you@work.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="flex-1 bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted"
                  autoComplete="email"
                />
                <button
                  type="submit"
                  disabled={sending || !email}
                  className="inline-flex items-center justify-center px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:cursor-not-allowed text-white font-semibold text-[14px] transition min-h-[48px] whitespace-nowrap"
                >
                  {sending ? 'sending…' : 'send link'}
                </button>
              </div>
            </form>
          )}

          {error && (
            <p
              role="alert"
              className="mt-4 p-3 bg-[rgba(239,68,68,0.08)] border border-[rgba(239,68,68,0.3)] rounded-[12px] text-[#FCA5A5] text-[13px] leading-[1.5]"
            >
              {error}
            </p>
          )}

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
