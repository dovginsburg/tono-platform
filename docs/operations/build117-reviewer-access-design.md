# Build 117 App-Review reviewer access — compatibility design (for Ezra review)

**Status:** proposed, implemented on branch, **NOT deployed**, coupon **NOT created in prod**. Stop for review.

## The promise vs. the live behavior

ASC review notes for Build 117 tell the reviewer: *skip onboarding → Settings > Plan → redeem `APPREVIEW117` with no purchase and no sign-in.* Build 117's UI says email sign-in is **"Coming soon"**, so the reviewer stays an **anonymous** (unidentified) canonical account.

Deployed SHA `185dc7b` **breaks that promise**: `/v1/coupon/redeem` returns **403** unless `account.is_identified`. The reviewer cannot sign in, so cannot redeem, so cannot see Pro → likely rejection.

## Three root causes (all had to be fixed for the path to actually work)

1. **Endpoint gate** — `server.redeem_coupon` hard-403s on `not is_identified`.
2. **Store gate** — `store._redeem_coupon_tx` raises "sign in" on `not is_identified`.
3. **Entitlement projection mismatch** — anonymous `User.is_pro` reads the **device** column `users.coupon_pro_expires_at`, but redemption wrote only the **account** column `accounts.coupon_pro_expires_at`. So even with both gates relaxed, an anonymous reviewer would still not see Pro.

## Smallest backward-compatible fix

A **per-coupon opt-in flag**, not a global relaxation:

- **Schema (additive):** `coupons.anonymous_eligible INTEGER NOT NULL DEFAULT 0` + an idempotent `ALTER TABLE`. Every existing and future coupon defaults to **identity-gated** — behavior unchanged.
- **Redeem gate (endpoint + store, defense in depth):** an unidentified account is refused for every code **except** one whose `anonymous_eligible=1`. Non-existent codes read as not-eligible (no existence oracle).
- **Anonymous projection:** when (and only when) the account is unidentified, the redemption also writes `users.coupon_pro_expires_at` for the **exact `(device_id, account_id)`** pair, so the existing anonymous `User.is_pro` path resolves. `User.is_pro` semantics are **unchanged** — we populate the field it already reads, rather than broaden the property.
- **Admin create** accepts `anonymous_eligible` (default False) so ops can mint `APPREVIEW117` with a **small `max_uses`** and a **near `expires_at`**.

Nothing else in the coupon transaction changes: expiry, `max_uses` (atomic `use_count` guard), and the `account_coupon_redemptions (account_id, code)` idempotency key are all reused as-is.

## Invariants preserved (pinned by `tests/test_coupon_reviewer_access.py`, 9 tests)

| Invariant | Test |
|---|---|
| Anonymous reviewer can redeem the flagged code and Pro unlocks | `..._unlocks_pro` |
| **Ownership unchanged** — anonymous refused for a normal code (403) | `..._refused_for_a_normal_coupon` |
| No existence oracle for anonymous | `..._unknown_code_does_not_leak_existence` |
| Idempotent per canonical account | `..._idempotent_per_account` |
| `max_uses` bounds distinct anonymous accounts | `..._respects_max_uses` |
| Expiry enforced even for the flagged code | `..._respects_expiry` |
| **No cross-device leakage** — grant binds to one account UUID | `..._does_not_leak_across_devices` |
| Identified accounts still redeem (flagged + normal) | `..._identified_account_still_redeems...` |
| Flag flows through admin API and **defaults off** | `..._admin_create_flag_flows_and_defaults_identity_gated` |

## Reversibility

Pure additive column + gated code path. Roll back by setting the coupon's `anonymous_eligible=0` (or deleting the coupon) — no data migration, no effect on any other coupon.

## Human-only follow-ups (NOT done here)

1. **Ezra review + approve** this design/diff.
2. **Deploy** the backend (Render) — currently `185dc7b` lacks the fix.
3. **Create `APPREVIEW117`** in prod via `POST /admin/coupon/create` with `anonymous_eligible: true`, a **bounded `max_uses`** (e.g. 25) and a **near `expires_at`** (e.g. review window + buffer). Admin secret required.
4. **ASC metadata corrections (not code):** the live review-contact **email uses a non-resolving `tonoit.app` address** and the **phone is a 555 placeholder** — fix both in App Store Connect. These are metadata, not backend changes.
