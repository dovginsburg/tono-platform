'use client';

// Passkey management for the signed-in account: list registered passkeys, add
// a new one (real WebAuthn registration ceremony), and revoke any of them.
// Server-authoritative throughout — the browser never holds the bearer; every
// call goes through the /api/passkey/* proxy which injects it from the httpOnly
// session cookie.

import { useCallback, useEffect, useState } from 'react';
import { startRegistration } from '@simplewebauthn/browser';
import { apiPath } from '@/lib/auth-redirects';

type Passkey = {
  credential_id: string;
  nickname?: string | null;
  transports: string[];
  created_at: string;
  last_used_at?: string | null;
};

type LoadState = 'loading' | 'ready' | 'error';

function formatDate(iso: string | null | undefined): string {
  if (!iso) return '';
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  } catch {
    return '';
  }
}

export default function PasskeyManager() {
  const [state, setState] = useState<LoadState>('loading');
  const [items, setItems] = useState<Passkey[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setState('loading');
    try {
      const res = await fetch(apiPath('/api/passkey/list'), { cache: 'no-store' });
      if (!res.ok) {
        setState('error');
        return;
      }
      setItems((await res.json()) as Passkey[]);
      setState('ready');
    } catch {
      setState('error');
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const add = async () => {
    setError(null);
    setBusy(true);
    try {
      const optRes = await fetch(apiPath('/api/passkey/register/options'), { method: 'POST' });
      if (optRes.status === 401) {
        setError('please sign in again to add a passkey.');
        return;
      }
      if (!optRes.ok) {
        setError("couldn't start passkey setup. try again in a moment.");
        return;
      }
      const optionsJSON = await optRes.json();

      let attestation;
      try {
        attestation = await startRegistration({ optionsJSON });
      } catch (e) {
        const name = (e as { name?: string })?.name;
        if (name === 'NotAllowedError' || name === 'AbortError') return;
        if (name === 'InvalidStateError') {
          setError('this device already has a passkey for your account.');
          return;
        }
        setError('passkey setup was cancelled or unsupported on this device.');
        return;
      }

      const nickname =
        typeof navigator !== 'undefined' && /Mobile|Android|iPhone/i.test(navigator.userAgent)
          ? 'this phone'
          : 'this device';

      const verifyRes = await fetch(apiPath('/api/passkey/register/verify'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ credential: attestation, nickname }),
      });
      if (!verifyRes.ok) {
        setError('that passkey could not be saved. please try again.');
        return;
      }
      await load();
    } finally {
      setBusy(false);
    }
  };

  const remove = async (credentialId: string) => {
    setError(null);
    setBusy(true);
    try {
      const res = await fetch(apiPath(`/api/passkey/${encodeURIComponent(credentialId)}`), {
        method: 'DELETE',
      });
      if (!res.ok && res.status !== 204) {
        setError("couldn't remove that passkey. please try again.");
        return;
      }
      await load();
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="space-y-4">
      <h2 className="text-[13px] font-semibold uppercase tracking-wider text-tono-text-softer">
        passkeys
      </h2>
      <p className="text-[14px] text-tono-text-soft leading-[1.6]">
        sign in with face id, touch id, windows hello, or a security key — no
        password to forget. add one on each device you use.
      </p>

      {state === 'loading' && (
        <p className="text-[13px] text-tono-text-softer">loading your passkeys…</p>
      )}

      {state === 'error' && (
        <div className="flex items-center gap-3">
          <p role="alert" className="text-[13px] text-tono-text-soft">
            couldn't load your passkeys.
          </p>
          <button
            type="button"
            onClick={() => void load()}
            className="text-[13px] text-tono-accent-light hover:underline"
          >
            retry
          </button>
        </div>
      )}

      {state === 'ready' && items.length === 0 && (
        <p className="text-[13px] text-tono-text-softer">
          no passkeys yet — add one for faster, phishing-resistant sign-in.
        </p>
      )}

      {state === 'ready' && items.length > 0 && (
        <ul className="space-y-2">
          {items.map((pk) => (
            <li
              key={pk.credential_id}
              className="flex items-center justify-between gap-4 rounded-[12px] border border-tono-border bg-tono-bg-card px-4 py-3"
            >
              <div className="min-w-0">
                <p className="text-[14px] text-tono-text truncate">
                  {pk.nickname || 'passkey'}
                </p>
                <p className="text-[12px] text-tono-text-softer">
                  added {formatDate(pk.created_at)}
                  {pk.last_used_at ? ` · last used ${formatDate(pk.last_used_at)}` : ''}
                </p>
              </div>
              <button
                type="button"
                onClick={() => remove(pk.credential_id)}
                disabled={busy}
                className="shrink-0 text-[13px] text-tono-danger hover:underline disabled:opacity-60"
              >
                remove
              </button>
            </li>
          ))}
        </ul>
      )}

      <button
        type="button"
        onClick={add}
        disabled={busy}
        className="inline-flex items-center justify-center gap-2 px-5 py-3 rounded-[12px] bg-transparent border border-tono-border-strong text-tono-text hover:border-tono-accent font-semibold transition min-h-[44px] text-[14px] disabled:opacity-60"
      >
        {busy ? 'waiting…' : 'add a passkey'}
      </button>

      {error && (
        <p role="alert" aria-live="assertive" className="text-[12px] text-tono-danger">
          {error}
        </p>
      )}
    </section>
  );
}
