// Web social-OAuth gating and iconography.
//
// Incident (verified live 2026-08-02): the website's Apple/Google OAuth path
// resolved a Supabase identity that is NOT the canonical native iOS/Apple/Google
// subject. Two concrete harms followed:
//   1. Apple's authorization screen showed a cross-product `client_id`, so a Tono
//      visitor saw another product's brand while signing in to Tono.
//   2. A user with an existing native Tono account who used web Google sign-in
//      landed in a *different* account — plain sign-in intentionally does not
//      merge by email, so the web button was a live account-fragmentation path.
//
// Containment: both web OAuth buttons are OFF by default and each re-enables only
// behind its OWN separately named public flag. There is deliberately no shared or
// generic truthy fallback — enabling one provider must never implicitly enable the
// other, and a stray non-empty value must never re-expose OAuth. The dedicated
// provider/linking architecture (native-subject-aware, email-linking-aware) is
// tracked separately; until it ships, these stay closed.

export interface OAuthFlagEnv {
  NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED?: string;
  NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED?: string;
}

// Strict opt-in: only the exact literal string 'true' enables a provider. Every
// other value — undefined, '', '1', 'yes', 'TRUE', 'false' — keeps it OFF. This
// avoids a truthy fallback so the buttons cannot be re-exposed by accident.
function isFlagEnabled(value: string | undefined): boolean {
  return value === 'true';
}

export function isAppleWebOAuthEnabled(env: OAuthFlagEnv): boolean {
  return isFlagEnabled(env.NEXT_PUBLIC_TONO_WEB_APPLE_OAUTH_ENABLED);
}

export function isGoogleWebOAuthEnabled(env: OAuthFlagEnv): boolean {
  return isFlagEnabled(env.NEXT_PUBLIC_TONO_WEB_GOOGLE_OAUTH_ENABLED);
}

// Apple logo, normalized to a 0 0 24 24 viewBox from the trusted simple-icons
// source (simpleicons.org, CC0). The previous hand-tuned path extended past the
// bottom of the box and clipped/distorted on mobile. Every command coordinate
// below — endpoints and Bézier control points alike — sits inside the viewBox,
// and because a Bézier curve is contained within the convex hull of its control
// points, the whole glyph is guaranteed to render inside the box. This is proven
// deterministically in social-auth.test.ts.
export const APPLE_ICON_VIEWBOX = '0 0 24 24';
export const APPLE_ICON_PATH =
  'M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 14.25 3.51 5.55 8.32 5.3c1.35.06 2.29.73 3.08.79 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.29 4.09zM12.03 5.25C11.88 3.02 13.69 1.18 15.77 1c.29 2.58-2.34 4.5-3.74 4.25z';
