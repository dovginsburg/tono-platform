// RevenueCat canary — web configuration (Build 123).
//
// RevenueCat is the first Tono canary for a unified subscription lifecycle. On the
// WEB the existing architecture is preserved deliberately:
//
//   * Web checkout stays Stripe-hosted. The existing Stripe Checkout + Customer
//     Portal flow (api/checkout, api/portal -> backend /v1/checkout, /v1/portal)
//     and the trial / cancel / refund semantics are UNCHANGED. We do NOT introduce
//     RevenueCat Billing, wallets, or a second checkout — that would move customers
//     off Stripe merely for neatness, which the canary brief forbids.
//   * The backend remains the sole entitlement authority. The web keeps reading
//     `is_pro` from /v1/me and never trusts a client flag.
//   * RevenueCat observes web subscriptions via its Stripe integration, attributed
//     to the SAME canonical account UUID (accounts.id) the backend already stamps
//     on the Stripe Customer and subscription as the `tono_account_id` metadata
//     field (apps/backend/payments.py) — that metadata field is what the RevenueCat
//     Stripe app must map to its App User ID so a web subscriber unifies under the
//     same identity as their iOS/Android purchases. (The Checkout session's
//     `client_reference_id` carries the device id, not the account UUID, so it is
//     NOT the field to map.) The RevenueCat App User ID is that account UUID —
//     never an email, device id, or anonymous RevenueCat id.
//
// This module only reads config and fails closed. It is dormant by default: with
// no config present it returns null and nothing in the web app changes. It exists
// so that if/when a web RevenueCat surface is enabled, the enablement + the
// publishable key are validated in one place rather than read ad hoc.

export type RevenueCatWebMode = 'off' | 'shadow' | 'authoritative';

export interface RevenueCatWebConfig {
  readonly mode: RevenueCatWebMode;
  readonly enabled: boolean;
  /** Publishable web-billing key (rcb_...). Publishable, never a secret. */
  readonly publicSdkKey: string;
}

const VALID_MODES: readonly RevenueCatWebMode[] = ['off', 'shadow', 'authoritative'];

function normalizeMode(raw: string | undefined): RevenueCatWebMode {
  const value = (raw ?? '').trim().toLowerCase();
  if (value === 'shadow' || value === 'authoritative') return value;
  // Anything unset / unrecognized => off (fail closed / dormant).
  return 'off';
}

/**
 * Load + validate the web RevenueCat config, failing closed.
 *
 * - mode defaults to 'off' (dormant): returns null so callers behave exactly as
 *   before RevenueCat existed.
 * - when mode is shadow/authoritative, a publishable key is REQUIRED; a missing
 *   key throws rather than silently enabling an unconfigured surface.
 */
export function loadRevenueCatWebConfig(
  env: Record<string, string | undefined>,
): RevenueCatWebConfig | null {
  const mode = normalizeMode(env.NEXT_PUBLIC_REVENUECAT_MODE);
  const publicSdkKey = (env.NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY ?? '').trim();

  if (mode === 'off') return null; // dormant: nothing changes

  if (!publicSdkKey) {
    throw new Error(
      'RevenueCat web is enabled (NEXT_PUBLIC_REVENUECAT_MODE=' +
        mode +
        ') but NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY is not set',
    );
  }

  return Object.freeze({
    mode,
    enabled: mode === 'shadow' || mode === 'authoritative',
    publicSdkKey,
  });
}

/** True only when a valid enabled config is present. Never throws. */
export function revenueCatWebEnabled(env: Record<string, string | undefined>): boolean {
  try {
    return loadRevenueCatWebConfig(env) !== null;
  } catch {
    return false;
  }
}

/** The valid modes, exported for tests and callers. */
export const REVENUECAT_WEB_MODES = VALID_MODES;
