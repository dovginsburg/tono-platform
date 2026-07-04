'use client';

import { useState } from 'react';
import { createClient } from '@/lib/supabase-client';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || '';

// build a basePath-aware redirect URI:
//   on tonoit.com, callback URL is https://tonoit.com/app/auth/callback
//   on localhost, callback URL is http://localhost:3000/app/auth/callback
function buildRedirectTo(): string {
  if (typeof window === 'undefined') return '';
  return `${window.location.origin}/app/auth/callback`;
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
    <main
      style={{
        minHeight: '100vh',
        display: 'grid',
        placeItems: 'center',
        padding: '48px 24px',
      }}
    >
      <div
        style={{
          width: '100%',
          maxWidth: 420,
          background: 'var(--bg-card)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius-lg)',
          padding: 28,
          boxShadow: '0 24px 64px rgba(0,0,0,0.4)',
        }}
      >
        <header style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 22 }}>
          <span
            aria-hidden
            style={{
              width: 10,
              height: 10,
              borderRadius: '50%',
              background: 'var(--accent)',
              boxShadow: '0 0 16px var(--accent-glow)',
            }}
          />
          <span style={{ fontWeight: 700, fontSize: 18, letterSpacing: '-0.02em' }}>tono</span>
        </header>

        <h1
          style={{
            fontSize: 28,
            lineHeight: '34px',
            fontWeight: 700,
            letterSpacing: '-0.02em',
            margin: '0 0 8px',
          }}
        >
          four ways to say it.
        </h1>
        <p style={{ color: 'var(--text-softer)', margin: '0 0 24px', fontSize: 14 }}>
          pick one, copy, send.
        </p>

        {/* OAuth buttons */}
        <button
          onClick={() => oauth('google')}
          style={btnPrimary}
          aria-label="Continue with Google"
        >
          <GoogleIcon /> continue with google
        </button>
        <button
          onClick={() => oauth('apple')}
          style={{ ...btnSecondary, marginTop: 10 }}
          aria-label="Continue with Apple"
        >
          <AppleIcon /> continue with apple
        </button>

        <Divider />

        {/* Magic link */}
        {magicSent ? (
          <div
            role="status"
            style={{
              background: 'var(--bg-elev)',
              border: '1px solid var(--border)',
              borderRadius: 'var(--radius-md)',
              padding: 14,
              fontSize: 14,
              color: 'var(--text-soft)',
            }}
          >
            <strong style={{ color: 'var(--text)' }}>check your inbox.</strong> a magic link is
            on its way. open it on this device to finish signing in.
          </div>
        ) : (
          <form onSubmit={sendMagic}>
            <label
              htmlFor="email"
              style={{
                display: 'block',
                fontSize: 12,
                color: 'var(--text-softer)',
                fontWeight: 500,
                letterSpacing: '0.02em',
                textTransform: 'uppercase',
                marginBottom: 6,
              }}
            >
              or — sign in with email
            </label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                id="email"
                type="email"
                required
                placeholder="you@work.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                style={inputStyle}
                autoComplete="email"
              />
              <button
                type="submit"
                disabled={sending || !email}
                style={{
                  ...btnPrimary,
                  opacity: sending || !email ? 0.6 : 1,
                  whiteSpace: 'nowrap',
                }}
              >
                {sending ? 'sending…' : 'send link'}
              </button>
            </div>
          </form>
        )}

        {error && (
          <p
            role="alert"
            style={{
              marginTop: 14,
              padding: 10,
              background: 'rgba(239,68,68,0.08)',
              border: '1px solid rgba(239,68,68,0.3)',
              borderRadius: 'var(--radius-md)',
              color: '#FCA5A5',
              fontSize: 13,
            }}
          >
            {error}
          </p>
        )}

        <p
          style={{
            marginTop: 28,
            fontSize: 12,
            color: 'var(--muted)',
            textAlign: 'center',
          }}
        >
          by signing in, you agree tono holds your drafts. nothing else.
        </p>

        {process.env.NODE_ENV !== 'production' && (
          <p
            style={{
              marginTop: 14,
              fontSize: 10,
              color: 'var(--muted)',
              wordBreak: 'break-all',
              opacity: 0.6,
            }}
          >
            supabase: {SUPABASE_URL}
          </p>
        )}
      </div>
    </main>
  );
}

const btnPrimary: React.CSSProperties = {
  width: '100%',
  display: 'inline-flex',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 10,
  padding: '12px 18px',
  background: 'var(--accent)',
  color: '#fff',
  border: '1px solid var(--accent)',
  borderRadius: 'var(--radius-md)',
  fontSize: 14,
  fontWeight: 600,
  transition: 'all var(--duration) var(--ease)',
  minHeight: 44,
};

const btnSecondary: React.CSSProperties = {
  ...btnPrimary,
  background: 'var(--bg-elev)',
  color: 'var(--text)',
  border: '1px solid var(--border)',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  background: 'var(--bg-elev)',
  color: 'var(--text)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-md)',
  padding: '12px 14px',
  fontSize: 14,
  outline: 'none',
  minHeight: 44,
};

function Divider() {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '1fr auto 1fr',
        alignItems: 'center',
        gap: 12,
        margin: '20px 0',
      }}
    >
      <div style={{ height: 1, background: 'var(--border)' }} />
      <span style={{ fontSize: 11, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>
        or
      </span>
      <div style={{ height: 1, background: 'var(--border)' }} />
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