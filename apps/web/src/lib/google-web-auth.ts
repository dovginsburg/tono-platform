// Direct, Tono-owned "Sign in with Google" for the web — GIS credential flow.
//
// This replaces the path where the website drove Google sign-in through
// Supabase's Google provider. On the shared Supabase project that provider is
// bound to a shared/umbrella Google Cloud project, so clicking Google sent a
// Tono user to a consent screen reading "continue to <shared>.supabase.co" — not
// Tono. The fix is to own the boundary: Google Identity Services (GIS) runs in
// the browser under Tono's OWN Web OAuth client id (from the Tono-owned Google
// Cloud project whose OAuth consent screen App name is "Tono"), returns a signed
// id token directly to a JS callback (no redirect, no client secret in the
// browser), and the page POSTs that id token to our server credential route,
// which forwards it to the canonical backend for authoritative verification.
//
// This module is tiny on purpose: GIS (loaded from Google) mints the token, the
// backend (`/v1/auth/google/web`, audience = the Tono Web client id) verifies it.
// Here we only keep the pure helpers the button gate + tests need.

/** The Google Identity Services client library. Loaded lazily by the button. */
export const GIS_CLIENT_SRC = 'https://accounts.google.com/gsi/client';

/** A Google OAuth Web client id always ends in `.apps.googleusercontent.com`. */
export function looksLikeGoogleClientId(value: string | undefined | null): boolean {
  const v = (value ?? '').trim();
  return v.length > 0 && /^[0-9]+-[a-z0-9_]+\.apps\.googleusercontent\.com$/.test(v);
}

/**
 * The public Web client id for the direct GIS flow, or `''` (fail closed) when
 * absent/foreign. Read from the deployment env; the value is public (GIS embeds
 * it in the browser), never a secret.
 */
export function readGooglePublicClientId(env: { NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID?: string }): string {
  const id = (env.NEXT_PUBLIC_GOOGLE_WEB_CLIENT_ID ?? '').trim();
  return looksLikeGoogleClientId(id) ? id : '';
}
