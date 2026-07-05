"use client";

import { useEffect, useState } from "react";
import { ensureDeviceToken } from "@/lib/device";

const API_URL = process.env.NEXT_PUBLIC_TONO_API_URL ?? "http://localhost:8765";

// TS's bundled DOM lib doesn't yet ship the WebAuthn L3 JSON helpers
// (parseCreationOptionsFromJSON / parseRequestOptionsFromJSON / toJSON on
// PublicKeyCredential), even though real browsers have shipped them since
// 2023 (Chrome 116+, Safari 17+, Firefox 122+) — using them avoids hand-
// rolling base64url<->ArrayBuffer conversions on both ends.
interface PublicKeyCredentialWithJSON extends PublicKeyCredential {
  toJSON(): unknown;
}
type PublicKeyCredentialCtor = typeof PublicKeyCredential & {
  parseCreationOptionsFromJSON(options: unknown): PublicKeyCredentialCreationOptions;
  parseRequestOptionsFromJSON(options: unknown): PublicKeyCredentialRequestOptions;
};

interface PasskeyListItem {
  credential_id: string;
  nickname: string | null;
  transports: string[];
  created_at: string;
  last_used_at: string | null;
}

async function authedFetch(path: string, token: string, body?: unknown, method = "POST") {
  const res = await fetch(`${API_URL}${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${path} failed (${res.status}): ${text}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

export function PasskeyAuth() {
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [passkeys, setPasskeys] = useState<PasskeyListItem[]>([]);

  // Checked in an effect, not inline during render: `window` doesn't exist
  // during SSR, so branching on it directly at render time renders
  // differently on the server than on the client and React flags a
  // hydration mismatch. Starting `false` and flipping after mount means
  // server and client render the same thing on the first pass.
  const [supported, setSupported] = useState(false);
  useEffect(() => {
    setSupported(!!window.PublicKeyCredential);
  }, []);

  async function refreshPasskeys() {
    try {
      const token = await ensureDeviceToken();
      const res = await fetch(`${API_URL}/v1/auth/passkey`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) return;
      setPasskeys(await res.json());
    } catch {
      // best-effort — the register/login buttons still work without this list
    }
  }

  useEffect(() => {
    if (supported) void refreshPasskeys();
  }, [supported]);

  async function register() {
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      const optionsJSON = await authedFetch("/v1/auth/passkey/register/options", token);
      const PKC = window.PublicKeyCredential as PublicKeyCredentialCtor;
      const publicKey = PKC.parseCreationOptionsFromJSON(optionsJSON);
      const credential = (await navigator.credentials.create({ publicKey })) as PublicKeyCredentialWithJSON | null;
      if (!credential) throw new Error("no credential returned");
      const verifyResult = await authedFetch("/v1/auth/passkey/register/verify", token, {
        credential: credential.toJSON(),
      });
      setStatus(`passkey registered — account ${verifyResult.account_id.slice(0, 8)}…`);
      await refreshPasskeys();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "registration failed");
    } finally {
      setBusy(false);
    }
  }

  async function removePasskey(credentialId: string) {
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      await authedFetch(`/v1/auth/passkey/${encodeURIComponent(credentialId)}`, token, undefined, "DELETE");
      setStatus("passkey removed");
      await refreshPasskeys();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "failed to remove passkey");
    } finally {
      setBusy(false);
    }
  }

  async function login() {
    setBusy(true);
    setStatus(null);
    try {
      const token = await ensureDeviceToken();
      const optionsRes = await fetch(`${API_URL}/v1/auth/passkey/login/options`, { method: "POST" });
      const optionsJSON = await optionsRes.json();
      const PKC = window.PublicKeyCredential as PublicKeyCredentialCtor;
      const publicKey = PKC.parseRequestOptionsFromJSON(optionsJSON);
      const credential = (await navigator.credentials.get({ publicKey })) as PublicKeyCredentialWithJSON | null;
      if (!credential) throw new Error("no credential returned");
      const verifyResult = await authedFetch("/v1/auth/passkey/login/verify", token, {
        credential: credential.toJSON(),
      });
      setStatus(`signed in — account ${verifyResult.account_id.slice(0, 8)}… (pro: ${verifyResult.is_pro})`);
      await refreshPasskeys();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "sign-in failed");
    } finally {
      setBusy(false);
    }
  }

  if (!supported) return null;

  return (
    <div className="passkey-auth" data-testid="passkey-auth">
      <div className="row">
        <button className="secondary" onClick={register} disabled={busy} data-testid="passkey-register">
          register a passkey
        </button>
        <button className="secondary" onClick={login} disabled={busy} data-testid="passkey-login">
          sign in with a passkey
        </button>
        {status && (
          <span className="muted-inline" data-testid="passkey-status">
            {status}
          </span>
        )}
      </div>
      {passkeys.length > 0 && (
        <ul className="passkey-list" data-testid="passkey-list">
          {passkeys.map((p) => (
            <li key={p.credential_id} data-testid="passkey-list-item">
              <span>{p.nickname || `passkey ${p.credential_id.slice(0, 8)}…`}</span>
              <button
                className="link-button"
                onClick={() => removePasskey(p.credential_id)}
                disabled={busy}
                data-testid="passkey-remove"
                aria-label={`remove ${p.nickname || "passkey"}`}
              >
                remove
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
