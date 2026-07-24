'use client';

// Standalone "sign in with a passkey" button for the login page. Runs the real
// WebAuthn assertion ceremony in the browser (Face ID / Touch ID / Windows
// Hello / security key) against the canonical backend via the /api/passkey/*
// proxy. No password, no fake button: if the authenticator or assertion fails,
// the user stays on the login page with an honest message.

import { useState } from 'react';
import { startAuthentication } from '@simplewebauthn/browser';
import { sanitizeNextPath } from '@/lib/auth-redirects';

export default function PasskeyLoginButton() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const signIn = async () => {
    setError(null);
    setBusy(true);
    try {
      // 1. Ask the server for a challenge (also mints the pending device).
      const startRes = await fetch('/api/passkey/login/start', { method: 'POST' });
      if (!startRes.ok) {
        setError("couldn't start a passkey sign-in. try another method.");
        return;
      }
      const optionsJSON = await startRes.json();

      // 2. Prompt the authenticator. Cancels throw NotAllowedError.
      let assertion;
      try {
        assertion = await startAuthentication({ optionsJSON });
      } catch (e) {
        const name = (e as { name?: string })?.name;
        if (name === 'NotAllowedError' || name === 'AbortError') {
          // User dismissed the prompt — not an error worth shouting about.
          return;
        }
        setError('no passkey was used. you can also sign in with email or a provider.');
        return;
      }

      // 3. Verify server-side; on success the session cookie is set.
      const finishRes = await fetch('/api/passkey/login/finish', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ credential: assertion }),
      });
      if (!finishRes.ok) {
        setError('that passkey could not be verified. try another sign-in method.');
        return;
      }

      // 4. Land where the visitor was headed (checkout/account) or the editor.
      const next = sanitizeNextPath(
        new URLSearchParams(window.location.search).get('next')
      );
      window.location.assign(next);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-2">
      <button
        type="button"
        onClick={signIn}
        disabled={busy}
        className="w-full inline-flex items-center justify-center gap-2 px-4 py-3 rounded-[12px] border border-tono-border-strong bg-tono-bg-elev text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px] disabled:opacity-60"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path
            d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5Zm3 8H9V7a3 3 0 0 1 6 0v3Z"
            fill="currentColor"
          />
        </svg>
        {busy ? 'waiting for your passkey…' : 'sign in with a passkey'}
      </button>
      {error && (
        <p role="alert" aria-live="assertive" className="text-[12px] text-tono-danger">
          {error}
        </p>
      )}
    </div>
  );
}
