# Mobile billing validation

The backend, not either mobile client, grants Pro. Both stores must be configured before enabling their endpoints.

## Apple

- `TONO_APPLE_ENVIRONMENT`: `Production` for App Store traffic; use `Sandbox` only on the explicit TestFlight/test backend lane.
- `TONO_APPLE_BUNDLE_ID`: expected app bundle (defaults to `com.tonoit.app`).
- `TONO_APPLE_APP_ID`: numeric App Store Connect app ID; required in Production by Apple's verifier.
- `TONO_APPLE_ROOT_CERTIFICATES`: `:`-separated DER certificate paths downloaded from Apple PKI.
- `TONO_APPLE_PRODUCT_IDS`: optional comma-separated allowlist; defaults to the current monthly/yearly Pro IDs.
- `TONO_APPLE_ONLINE_CHECKS`: defaults to `true` for certificate revocation/expiry checks.

Configure App Store Server Notifications V2 to POST to `/v1/app-store/notifications` on the matching environment lane.

## Google Play

- `GOOGLE_APPLICATION_CREDENTIALS`: service-account JSON with Android Publisher access, or use Application Default Credentials.
- `TONO_GOOGLE_PACKAGE_NAME`: authoritative package name (defaults to `com.tono.myapp`).
- `TONO_GOOGLE_PRODUCT_IDS`: optional comma-separated allowlist; defaults to the current monthly/yearly Pro IDs.

Configure Google Play real-time developer notifications through Pub/Sub push to `/v1/google-play/notifications`. The notification token is never trusted by itself; the handler resolves it through `purchases.subscriptionsv2.get` before changing entitlement.

## Threat boundary

This protects against forged client product/tier claims, wrong app/environment payloads, token reuse across accounts, and stale/retried provider events. It trusts the backend process, its SQLite database, configured store credentials, and the official provider APIs/libraries; it does not attempt to survive a hostile backend runtime or database administrator.

## Rollback

Revert the billing patch and redeploy the prior backend. The additive `mobile_purchases`, `mobile_billing_events`, and nullable `mobile_subscription_*` columns may remain safely in SQLite; older code ignores them, so no destructive down migration is required.
