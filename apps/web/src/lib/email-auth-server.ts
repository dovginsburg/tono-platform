// Server-only half of the web email-account surface.
//
// Every email flow on the website goes through the SAME canonical backend
// endpoints iOS and Android use. That is the whole design: not a second login
// system that happens to live on the web, but the same one reached from a
// fourth surface. It is what makes the registration ledger count a web signup,
// the anti-enumeration answers identical across surfaces, and the canonical
// account the person lands on the same account whichever surface they started
// from.
//
// Nothing here returns a backend or provider sentence to the browser. The
// response STATUS selects a reviewed code (see `classifyBackendStatus`) and the
// code selects a reviewed sentence on the client. A body is read only when it
// carries session fields this server needs itself.

import 'server-only';
import { cookies } from 'next/headers';

import {
  classifyBackendStatus,
  type EmailAuthOutcome,
} from './email-auth';

/** The surface tag every web-originated registration event is recorded under. */
export const WEB_SURFACE = 'web';

/**
 * The build tag the web sends on email-account calls.
 *
 * Matches what `/auth/callback` already sends, so a person's registration and
 * their later sign-ins are attributed to one surface and one build rather than
 * looking like two different clients.
 */
export const WEB_APP_VERSION = 'web-114';

function backendUrl(): string {
  return process.env.TONO_BACKEND_URL || 'https://api.tonoit.com';
}

export type BackendSession = {
  api_token?: string;
  account_id?: string;
  plan?: string;
  is_pro?: boolean;
  email?: string;
};

export type EmailAuthCall = {
  outcome: EmailAuthOutcome;
  session: BackendSession | null;
};

/**
 * Call one canonical email-auth endpoint and classify the result.
 *
 * `bearer` is forwarded when the browser already holds a canonical session, so
 * a person who registers an address while signed in upgrades the account they
 * are already using instead of starting a second one — the same
 * upgrade-in-place property the native clients get from their device bearer.
 */
export async function callEmailAuth(
  path: string,
  body: Record<string, unknown>,
  accepted: EmailAuthOutcome,
  bearer?: string
): Promise<EmailAuthCall> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (bearer) headers.Authorization = `Bearer ${bearer}`;

  let response: Response;
  try {
    response = await fetch(`${backendUrl()}${path}`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        ...body,
        source_surface: WEB_SURFACE,
        app_version: WEB_APP_VERSION,
      }),
      cache: 'no-store',
    });
  } catch {
    // Deliberately does not log or inspect the caught failure: its message
    // carries the request URL, and on a TLS or DNS failure the host as well.
    // That the call could not be completed is the whole diagnosable fact.
    return { outcome: 'offline', session: null };
  }

  const outcome = classifyBackendStatus(response.status, accepted);
  if (!response.ok) return { outcome, session: null };

  try {
    const parsed = (await response.json()) as BackendSession;
    return { outcome, session: parsed && typeof parsed === 'object' ? parsed : null };
  } catch {
    return { outcome, session: null };
  }
}

/**
 * Store a canonical session in the cookies the rest of the site reads.
 *
 * Identical to what `/auth/callback` sets, so a password sign-in and an OAuth
 * or magic-link sign-in leave the browser in exactly the same state and no
 * downstream surface has to know which one happened.
 */
export async function storeCanonicalSession(session: BackendSession): Promise<void> {
  if (!session.api_token) return;
  const cookieStore = await cookies();
  // httpOnly so the editor and checkout can reach the backend through this
  // server without re-minting, and so no script on the page can read it.
  cookieStore.set('tono_api_token', session.api_token, {
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365, // 1y; rotated on re-auth
  });
  cookieStore.set('tono_plan', session.plan || 'free', {
    httpOnly: false,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
  });
}

/** The canonical bearer this browser already holds, if any. */
export async function currentBearer(): Promise<string | undefined> {
  const cookieStore = await cookies();
  return cookieStore.get('tono_api_token')?.value;
}
