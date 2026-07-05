"use client";

import { useEffect, useRef, useState } from "react";
import { ensureDeviceToken } from "@/lib/device";

const API_URL = process.env.NEXT_PUBLIC_TONO_API_URL ?? "http://localhost:8765";
const GOOGLE_CLIENT_ID = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID ?? "";
const APPLE_CLIENT_ID = process.env.NEXT_PUBLIC_APPLE_CLIENT_ID ?? "";

// Minimal shapes for the two vendor SDKs — neither ships its own npm
// @types package worth pulling in for four call sites.
interface GoogleCredentialResponse {
  credential: string; // the ID token — exactly what POST /v1/auth/google wants
}
interface GoogleIdentityServices {
  accounts: {
    id: {
      initialize(config: { client_id: string; callback: (r: GoogleCredentialResponse) => void }): void;
      renderButton(el: HTMLElement, options: { type: string; theme: string; text: string; shape: string }): void;
    };
  };
}
interface AppleAuthSignInResult {
  authorization: { id_token: string };
}
interface AppleIdSdk {
  auth: {
    init(config: { clientId: string; scope: string; redirectURI: string; usePopup: boolean }): void;
    signIn(): Promise<AppleAuthSignInResult>;
  };
}
declare global {
  interface Window {
    google?: GoogleIdentityServices;
    AppleID?: AppleIdSdk;
  }
}

function loadScript(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(`failed to load ${src}`));
    document.head.appendChild(script);
  });
}

async function completeSignIn(path: "google" | "apple", tokenField: string, token: string) {
  const deviceToken = await ensureDeviceToken();
  const res = await fetch(`${API_URL}/v1/auth/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${deviceToken}` },
    body: JSON.stringify({ [tokenField]: token }),
  });
  if (!res.ok) throw new Error(`sign-in failed (${res.status})`);
  return res.json();
}

/**
 * Both buttons post straight to the existing /v1/auth/apple and
 * /v1/auth/google endpoints (see Backend/server.py) — this component is
 * just the client-side half that was missing; the backend has supported
 * both since the account layer went in.
 *
 * NOT verified end-to-end in this sandbox, for two different reasons:
 * - Apple: appleid.cdn-apple.com is blocked outright by this sandbox's
 *   network policy (curl to it 403s), so the script can't even load here.
 * - Google: curl can reach accounts.google.com/gsi/client directly (200),
 *   but a Playwright-launched Chromium hitting the same URL gets
 *   ERR_CONNECTION_RESET, with or without proxy config — the sandbox's
 *   network isolation appears to key off the requesting process, not just
 *   the destination host, and headless-browser traffic is cut off in a way
 *   plain curl isn't. This is a test-harness limitation, not a signal about
 *   the component itself.
 *
 * Both integrations follow the vendors' documented client-side APIs
 * (Google Identity Services `initialize`/`renderButton`; Apple JS SDK
 * `auth.init`/`auth.signIn`) and typecheck cleanly, but neither has run a
 * real credential exchange against this backend. Test both for real on a
 * machine with real developer-console client IDs before shipping.
 */
export function SocialSignIn() {
  const [status, setStatus] = useState<string | null>(null);
  const googleBtnRef = useRef<HTMLDivElement>(null);
  const [appleReady, setAppleReady] = useState(false);

  useEffect(() => {
    if (!GOOGLE_CLIENT_ID) return;
    loadScript("https://accounts.google.com/gsi/client")
      .then(() => {
        if (!window.google || !googleBtnRef.current) return;
        window.google.accounts.id.initialize({
          client_id: GOOGLE_CLIENT_ID,
          callback: async (response) => {
            try {
              const result = await completeSignIn("google", "id_token", response.credential);
              setStatus(`signed in with google — account ${result.account_id.slice(0, 8)}…`);
            } catch (err) {
              setStatus(err instanceof Error ? err.message : "google sign-in failed");
            }
          },
        });
        window.google.accounts.id.renderButton(googleBtnRef.current, {
          type: "standard",
          theme: "filled_black",
          text: "signin_with",
          shape: "pill",
        });
      })
      .catch(() => setStatus((s) => s ?? null)); // stay silent — this is an optional feature
  }, []);

  useEffect(() => {
    if (!APPLE_CLIENT_ID) return;
    loadScript("https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js")
      .then(() => {
        window.AppleID?.auth.init({
          clientId: APPLE_CLIENT_ID,
          scope: "email",
          redirectURI: typeof window !== "undefined" ? window.location.origin : "",
          usePopup: true,
        });
        setAppleReady(true);
      })
      .catch(() => setAppleReady(false));
  }, []);

  async function signInWithApple() {
    try {
      const result = await window.AppleID?.auth.signIn();
      if (!result) throw new Error("no result from Apple");
      const signinResult = await completeSignIn("apple", "identity_token", result.authorization.id_token);
      setStatus(`signed in with apple — account ${signinResult.account_id.slice(0, 8)}…`);
    } catch (err) {
      setStatus(err instanceof Error ? err.message : "apple sign-in failed");
    }
  }

  if (!GOOGLE_CLIENT_ID && !APPLE_CLIENT_ID) return null;

  return (
    <div className="row" data-testid="social-signin">
      {GOOGLE_CLIENT_ID && <div ref={googleBtnRef} data-testid="google-signin-button" />}
      {APPLE_CLIENT_ID && appleReady && (
        <button className="secondary" onClick={signInWithApple} data-testid="apple-signin-button">
          sign in with apple
        </button>
      )}
      {status && (
        <span className="muted-inline" data-testid="social-signin-status">
          {status}
        </span>
      )}
    </div>
  );
}
