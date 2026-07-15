# Mobile billing validation

The backend, not either mobile client, grants Pro. Both stores must be configured before enabling their endpoints.

## Apple

- `TONO_APPLE_ENVIRONMENT`: `Production` for App Store traffic; use `Sandbox` only on the explicit TestFlight/test backend lane.
- `TONO_APPLE_BUNDLE_ID`: expected app bundle (defaults to `com.tonoit.app`).
- `TONO_APPLE_APP_ID`: numeric App Store Connect app ID; required in Production by Apple's verifier.
- `TONO_APPLE_ROOT_CERTIFICATES`: `:`-separated DER certificate paths downloaded from Apple PKI.
- `TONO_APPLE_PRODUCT_IDS`: optional comma-separated allowlist; defaults to the current monthly/yearly Pro IDs.
- `TONO_APPLE_ONLINE_CHECKS`: defaults to `true` for certificate revocation/expiry checks.
- `TONO_APPLE_LEGACY_CLAIM_BEFORE_MS`: optional App Store purchase-date cutoff for restoring pre-build-88 transactions that have no `appAccountToken`. Leave unset after the migration window; tokenized purchases never use this exception.

Configure App Store Server Notifications V2 to POST to `/v1/app-store/notifications` on the matching environment lane.

## Google Play

- `GOOGLE_APPLICATION_CREDENTIALS`: service-account JSON with Android Publisher access, or use Application Default Credentials.
- `TONO_GOOGLE_PACKAGE_NAME`: authoritative package name (defaults to `com.tono.myapp`).
- `TONO_GOOGLE_PRODUCT_IDS`: optional comma-separated allowlist; defaults to the current monthly/yearly Pro IDs.
- `TONO_GOOGLE_LEGACY_CLAIM_BEFORE_MS`: optional Google Play purchase-start cutoff for restoring purchases created before the Android client supplied `obfuscatedExternalAccountId`. Leave unset after the migration window; purchases with an account identifier must always match it.

Configure Google Play real-time developer notifications through Pub/Sub push to `/v1/google-play/notifications`. The notification token is never trusted by itself; the handler resolves it through `purchases.subscriptionsv2.get` before changing entitlement.

## Threat boundary

This protects against forged client product/tier claims, wrong app/environment payloads, token reuse across accounts, and stale/retried provider events. It trusts the backend process, its SQLite database, configured store credentials, and the official provider APIs/libraries; it does not attempt to survive a hostile backend runtime or database administrator. The two explicit legacy migration switches relax attacker-first ownership binding for otherwise unowned pre-token purchases, so run them only on a time-bounded migration lane; the purchase uniqueness constraint still prevents later cross-account attachment.

## TestFlight purchase acceptance matrix

Run this matrix against an explicit Sandbox backend lane before promoting a new iOS candidate. Do not point the candidate at the Production validation lane: TestFlight StoreKit transactions are Sandbox transactions.

| Scenario | Expected app result | Expected backend result |
| --- | --- | --- |
| Eligible annual purchase | Paywall closes; Settings shows `Trial`; keyboard entitlement unlocks | `/v1/me` is authoritative with `is_pro=true` and an active mobile subscription |
| Paid monthly purchase or ineligible annual purchase | Paywall closes; Settings shows `Pro` and never claims a trial | `/v1/me` is authoritative with `is_pro=true` |
| User cancels the purchase sheet | Paywall stays open and shows `Purchase canceled.` | No entitlement change |
| Ask-to-Buy or other pending purchase | Paywall stays open and shows the pending message | No entitlement until a verified transaction update is reconciled |
| Unverified transaction | Paywall stays open and shows verification failure | No entitlement change |
| Relaunch after successful purchase | `Trial` or `Pro` is restored; keyboard entitlement remains unlocked | Current StoreKit entitlement is revalidated and `/v1/me` remains active |
| Restore after reinstall or stale local state | Restore repairs `Trial`/`Pro`; server-validation failures remain visible | Signed current entitlement reattaches only to its existing owner |
| Refund/revoke/cancel update | Access disappears after refresh/relaunch | Notification reconciliation makes `/v1/me.is_pro=false` |

Sherlock physical acceptance must also type `Shift, a, b` → `Ab`, double-Shift then `a, b` → `AB`, and unlock Caps Lock then `c` → `c` in Messages and one ordinary text field, checking both output and Shift icon state.

## Rollback

Revert the billing candidate and redeploy the prior backend/app candidate. The additive `mobile_purchases`, `mobile_billing_events`, and nullable `mobile_subscription_*` columns may remain safely in SQLite; older code ignores them, so no destructive down migration is required.
