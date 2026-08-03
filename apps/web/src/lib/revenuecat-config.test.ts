import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

import {
  loadRevenueCatWebConfig,
  revenueCatWebEnabled,
  REVENUECAT_WEB_MODES,
} from './revenuecat-config.ts';

function src(rel: string): string {
  return readFileSync(new URL(rel, import.meta.url), 'utf8');
}

// ---------------------------------------------------------------------------
// Config loader: fail-closed, dormant by default
// ---------------------------------------------------------------------------

test('unset config is dormant (returns null, nothing changes)', () => {
  assert.equal(loadRevenueCatWebConfig({}), null);
  assert.equal(revenueCatWebEnabled({}), false);
});

test('mode=off is dormant even with a key present', () => {
  const env = { NEXT_PUBLIC_REVENUECAT_MODE: 'off', NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY: 'rcb_x' };
  assert.equal(loadRevenueCatWebConfig(env), null);
});

test('garbage mode normalizes to off (fail closed)', () => {
  assert.equal(loadRevenueCatWebConfig({ NEXT_PUBLIC_REVENUECAT_MODE: 'nonsense' }), null);
});

test('enabled mode with a publishable key yields a frozen enabled config', () => {
  for (const mode of ['shadow', 'authoritative'] as const) {
    const cfg = loadRevenueCatWebConfig({
      NEXT_PUBLIC_REVENUECAT_MODE: mode,
      NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY: 'rcb_public',
    });
    assert.ok(cfg, `${mode} should load`);
    assert.equal(cfg!.mode, mode);
    assert.equal(cfg!.enabled, true);
    assert.equal(cfg!.publicSdkKey, 'rcb_public');
    assert.throws(() => {
      // frozen
      (cfg as unknown as { mode: string }).mode = 'off';
    });
  }
});

test('enabled mode WITHOUT a key throws (never silently enables)', () => {
  assert.throws(
    () => loadRevenueCatWebConfig({ NEXT_PUBLIC_REVENUECAT_MODE: 'shadow' }),
    /NEXT_PUBLIC_REVENUECAT_PUBLIC_SDK_KEY is not set/,
  );
  // ...and the boolean helper never throws — it reports false on misconfig.
  assert.equal(revenueCatWebEnabled({ NEXT_PUBLIC_REVENUECAT_MODE: 'shadow' }), false);
});

test('modes are exactly off/shadow/authoritative', () => {
  assert.deepEqual([...REVENUECAT_WEB_MODES], ['off', 'shadow', 'authoritative']);
});

// ---------------------------------------------------------------------------
// Source contract: the existing Stripe path is preserved (no RC Billing/wallets)
// ---------------------------------------------------------------------------

test('web checkout still goes to Stripe via the backend (unchanged)', () => {
  const checkout = src('../app/api/checkout/route.ts');
  assert.ok(checkout.includes('/v1/checkout'), 'checkout must still proxy to the backend Stripe checkout');
  assert.ok(!/revenuecat/i.test(checkout), 'checkout must NOT be rerouted to RevenueCat (no duplicate checkout)');
});

test('customer portal still goes to Stripe via the backend (unchanged)', () => {
  const portal = src('../app/api/portal/route.ts');
  assert.ok(portal.includes('/v1/portal'), 'portal must still proxy to the backend Stripe portal');
  assert.ok(!/revenuecat/i.test(portal), 'portal must NOT be rerouted to RevenueCat');
});

test('no RevenueCat Billing / wallet was introduced on the web', () => {
  // Strip comment markers + collapse whitespace so the documented invariant is
  // matched regardless of how the comment wraps across lines.
  const cfg = src('./revenuecat-config.ts').replace(/\/\//g, ' ').replace(/\s+/g, ' ');
  assert.ok(/Stripe-hosted/i.test(cfg), 'must document that web checkout stays Stripe-hosted');
  assert.ok(/do NOT introduce RevenueCat Billing/i.test(cfg), 'must forbid RevenueCat Billing');
  assert.ok(/wallets/i.test(cfg), 'must forbid wallets');
});

test('RevenueCat App User ID is the canonical account UUID (documented)', () => {
  const cfg = src('./revenuecat-config.ts');
  assert.ok(/account UUID/i.test(cfg));
  assert.ok(/client_reference_id/i.test(cfg));
  assert.ok(/never an email, device id, or anonymous/i.test(cfg));
});

test('web binding names the Stripe metadata field RevenueCat maps (tono_account_id)', () => {
  // The canonical UUID reaches Stripe as subscription/customer metadata
  // `tono_account_id` (client_reference_id carries the device id); RevenueCat's
  // Stripe integration must map THAT field so web unifies with iOS/Android.
  const cfg = src('./revenuecat-config.ts');
  assert.ok(/tono_account_id/.test(cfg), 'must name the Stripe metadata field to map');
  // The mapped field must be the account metadata, not client_reference_id.
  assert.ok(
    /client_reference_id[^.]*device id/is.test(cfg),
    'must clarify client_reference_id is the device id, not the account UUID',
  );
});

test('payment history renders a revenuecat provider label', () => {
  const ph = src('../app/account/PaymentHistory.tsx');
  assert.ok(/revenuecat:\s*'revenuecat'/.test(ph), 'PROVIDER_LABEL must include a revenuecat entry');
});

test('backend stays the entitlement authority on the web (is_pro from /v1/me)', () => {
  const me = src('../app/api/me/route.ts');
  assert.ok(me.includes('/v1/me'), 'the web must keep reading entitlement from the backend /v1/me');
});
