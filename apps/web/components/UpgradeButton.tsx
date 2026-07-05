"use client";

import { useEffect, useState } from "react";
import { ensureDeviceToken } from "@/lib/device";

const API_URL = process.env.NEXT_PUBLIC_TONO_API_URL ?? "http://localhost:8765";

async function authedFetch(path: string, token: string, body?: unknown) {
  const res = await fetch(`${API_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${path} failed (${res.status}): ${text}`);
  }
  return res.json();
}

/**
 * Stripe Checkout (new subscription) / Billing Portal (manage an existing
 * one) — both endpoints just hand back a URL to redirect the whole page
 * to; Stripe's own hosted pages do the rest, and redirect back to
 * /v1/checkout/return when done. Whether this renders "upgrade" or
 * "manage subscription" depends on GET /v1/me's `is_pro`, fetched once on
 * mount — same device-token bootstrap as PasskeyAuth/SocialSignIn.
 *
 * Not verified end-to-end in this sandbox: api.stripe.com/checkout.stripe.com
 * are both network-blocked here, so the actual Stripe-hosted pages were
 * never reached. What IS verified: the button correctly calls
 * /v1/checkout or /v1/portal and surfaces the backend's real response —
 * against this sandbox's backend (no STRIPE_SECRET_KEY configured) that's
 * a clean 503 "Stripe is not configured on this server," which is the
 * exact graceful-degradation path a deployment without Stripe configured
 * would also hit.
 */
export function UpgradeButton() {
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [isPro, setIsPro] = useState<boolean | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const token = await ensureDeviceToken();
        const res = await fetch(`${API_URL}/v1/me`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (!res.ok) return;
        const me = await res.json();
        setIsPro(Boolean(me.is_pro));
      } catch {
        // best-effort — button still renders (defaults to "upgrade") without this
      }
    })();
  }, []);

  async function upgrade() {
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      const result = await authedFetch("/v1/checkout", token, { interval: "month" });
      window.location.href = result.url;
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "checkout failed");
      setBusy(false);
    }
  }

  async function manage() {
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      const result = await authedFetch("/v1/portal", token);
      window.location.href = result.url;
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "opening billing portal failed");
      setBusy(false);
    }
  }

  return (
    <div className="row" data-testid="upgrade-button">
      {isPro ? (
        <button className="secondary" onClick={manage} disabled={busy} data-testid="manage-subscription">
          manage subscription
        </button>
      ) : (
        <button className="primary" onClick={upgrade} disabled={busy} data-testid="upgrade-to-pro">
          upgrade to pro
        </button>
      )}
      {status && (
        <span className="muted-inline" data-testid="upgrade-status">
          {status}
        </span>
      )}
    </div>
  );
}
