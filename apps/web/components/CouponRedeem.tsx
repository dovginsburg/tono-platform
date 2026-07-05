"use client";

import { useState } from "react";
import { ensureDeviceToken } from "@/lib/device";

const API_URL = process.env.NEXT_PUBLIC_TONO_API_URL ?? "http://localhost:8765";

/**
 * Promo/coupon code redemption — POST /v1/coupon/redeem grants Pro for the
 * code's configured duration. Backend validates: code exists, not
 * expired, under its max-uses cap, and not already redeemed by this
 * device (see apps/backend/tests/test_api.py's coupon tests) — this
 * component just surfaces whatever message the backend returns for each
 * of those cases rather than re-validating client-side.
 */
export function CouponRedeem() {
  const [code, setCode] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function redeem() {
    const trimmed = code.trim();
    if (!trimmed) return;
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      const res = await fetch(`${API_URL}/v1/coupon/redeem`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ code: trimmed }),
      });
      const body = await res.json();
      if (!res.ok) {
        throw new Error(body?.error?.message ?? `redeem failed (${res.status})`);
      }
      setStatus(body.message ?? "code redeemed");
      setCode("");
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "redeem failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="row" data-testid="coupon-redeem">
      <input
        type="text"
        placeholder="promo code"
        value={code}
        onChange={(e) => setCode(e.target.value)}
        disabled={busy}
        data-testid="coupon-input"
      />
      <button
        className="secondary"
        onClick={redeem}
        disabled={busy || !code.trim()}
        data-testid="coupon-submit"
      >
        redeem
      </button>
      {status && (
        <span className="muted-inline" data-testid="coupon-status">
          {status}
        </span>
      )}
    </div>
  );
}
