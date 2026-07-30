'use client';

import { useState } from 'react';
import { apiPath } from '@/lib/auth-redirects';

export default function PromoRedemption() {
  const [code, setCode] = useState('');
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function redeem(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setNotice(null);
    try {
      const response = await fetch(apiPath('/api/coupon/redeem'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code }),
      });
      if (response.ok) {
        setCode('');
        setNotice('promo applied to your Tono account. Refreshing your plan…');
        window.location.reload();
      } else {
        setNotice(response.status === 409 ? 'that promo was already used on this account.' : 'that promo could not be applied.');
      }
    } catch {
      setNotice('we could not apply that promo right now. try again shortly.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-3">
      <h2 className="text-[13px] font-semibold uppercase tracking-wider text-tono-text-softer">
        promo code
      </h2>
      <p className="text-[14px] text-tono-text-soft">
        promos attach to this Tono account and follow you to iPhone and Android after sign-in.
      </p>
      <form onSubmit={redeem} className="flex gap-2">
        <input
          aria-label="promo code"
          value={code}
          onChange={(event) => setCode(event.target.value)}
          className="min-w-0 flex-1 bg-tono-bg-elev border border-tono-border rounded-[12px] px-4 py-3"
        />
        <button disabled={busy || !code.trim()} className="px-5 rounded-[12px] bg-tono-accent text-white font-semibold disabled:opacity-60">
          {busy ? 'applying…' : 'apply'}
        </button>
      </form>
      {notice ? <p role={notice.includes('applied') ? 'status' : 'alert'} className="text-[13px] text-tono-text-soft">{notice}</p> : null}
    </section>
  );
}
