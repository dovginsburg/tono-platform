'use client';

import { useState } from 'react';
import Link from 'next/link';

import {
  EMAIL_AUTH_COPY,
  MIN_PASSWORD_LENGTH,
  sanitizeEmailAuthOutcome,
  validateNewPassword,
  type EmailAuthOutcome,
} from '@/lib/email-auth';
import { APP_ENTRY_PATH, apiPath, LOGIN_PATH } from '@/lib/auth-redirects';

/**
 * The password-choosing form.
 *
 * Confirmation field is not optional politeness: this is the one place in the
 * product where a typo is unrecoverable by the person who made it — they would
 * be locked out of an account they just proved they own, with the only way back
 * being another round of the flow they are already in the middle of.
 *
 * There is no state here that can hold a sentence from the server. Every string
 * shown comes from EMAIL_AUTH_COPY, selected by a reviewed code, so no provider
 * or transport text can be rendered by this component.
 */
export function ResetPasswordForm() {
  const [password, setPassword] = useState('');
  const [confirmation, setConfirmation] = useState('');
  const [saving, setSaving] = useState(false);
  const [outcome, setOutcome] = useState<EmailAuthOutcome | null>(null);

  const done = outcome === 'password_updated';

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const local = validateNewPassword(password, confirmation);
    if (local) {
      setOutcome(local);
      return;
    }
    setOutcome(null);
    setSaving(true);
    try {
      const res = await fetch(apiPath('/api/auth/password'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password, confirmation }),
      });
      const data = (await res.json()) as { outcome?: string };
      setOutcome(sanitizeEmailAuthOutcome(data.outcome) ?? 'unknown_failure');
    } catch {
      setOutcome('offline');
    } finally {
      setSaving(false);
    }
  };

  if (done) {
    return (
      <div className="space-y-5">
        <div
          role="status"
          className="bg-tono-bg-elev border border-tono-border rounded-[12px] p-4 text-[14px] text-tono-text-soft leading-[1.55]"
        >
          <strong className="text-tono-text">{EMAIL_AUTH_COPY.password_updated}</strong>{' '}
          you&apos;re signed in here. on your phone, sign in with your email and the new
          password.
        </div>
        <Link
          href={APP_ENTRY_PATH}
          className="w-full inline-flex items-center justify-center px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover text-white font-semibold text-[14px] transition min-h-[48px]"
        >
          start writing
        </Link>
      </div>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-3">
      <div>
        <label
          htmlFor="new-password"
          className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
        >
          new password
        </label>
        <input
          id="new-password"
          type="password"
          required
          minLength={MIN_PASSWORD_LENGTH}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete="new-password"
          className="w-full bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted"
          placeholder={`at least ${MIN_PASSWORD_LENGTH} characters`}
        />
      </div>
      <div>
        <label
          htmlFor="confirm-password"
          className="block text-[11px] font-semibold tracking-wider uppercase text-tono-text-softer mb-1.5"
        >
          type it again
        </label>
        <input
          id="confirm-password"
          type="password"
          required
          minLength={MIN_PASSWORD_LENGTH}
          value={confirmation}
          onChange={(e) => setConfirmation(e.target.value)}
          autoComplete="new-password"
          className="w-full bg-tono-bg-elev text-tono-text border border-tono-border rounded-[12px] px-4 py-3 text-[14px] outline-none focus:border-tono-border-strong min-h-[48px] placeholder:text-tono-muted"
        />
      </div>

      <button
        type="submit"
        disabled={saving || !password || !confirmation}
        className="w-full inline-flex items-center justify-center px-5 py-3 rounded-[12px] bg-tono-accent hover:bg-tono-accent-hover disabled:opacity-60 disabled:cursor-not-allowed text-white font-semibold text-[14px] transition min-h-[48px]"
      >
        {saving ? 'saving…' : 'save new password'}
      </button>

      {outcome && !done && (
        <p
          role="alert"
          className="mt-1 p-3 bg-[rgba(239,68,68,0.08)] border border-[rgba(239,68,68,0.3)] rounded-[12px] text-[#FCA5A5] text-[13px] leading-[1.5]"
        >
          {EMAIL_AUTH_COPY[outcome]}
          {outcome === 'link_expired' && (
            <>
              {' '}
              <Link href={LOGIN_PATH} className="underline">
                request a new one
              </Link>
              .
            </>
          )}
        </p>
      )}
    </form>
  );
}
