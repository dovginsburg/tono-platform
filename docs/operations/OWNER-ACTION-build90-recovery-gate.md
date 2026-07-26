# Owner action — build-90 charged-before-upgrade gate

> **CLOSED 2026-07-25 — superseded by
> [`BUILD90-OWNER-ATTESTATION-2026-07-25.md`](BUILD90-OWNER-ATTESTATION-2026-07-25.md).**
>
> Dov Ginsburg attested that no one has paid for Tono through Stripe, App Store,
> or Google Play, so no charged build-90 user exists and no historical
> entitlement restoration is required. Closed via **Option B / Form B** below,
> over an attested **empty** population. Form A (`checkout_disabled`) remains
> `supplied: false` — no App Store Connect observation was made.
>
> The gate's executable verification **was run** against this artifact before the
> closing commit, with `TONO_BUILD90_RECOVERY_EVIDENCE` unset:
> `build90-recovery-gate: READY (evidence via artifact)` (exit 0) and
> `build91-entitlement-contract: PASS` (exit 0). QA should re-run both in §5 as
> an independent reproduction before any store upload.
>
> The rest of this document is retained as the original staged decision brief.

**Original status (now superseded): BLOCKED, fail-closed. One decision by Dov
unblocks it. Nothing in this file has been filled in, approved, or inferred by
the release session.**

Candidate: the single linear successor to `5d3fdd7e385391d004e758be6ca759e4ff819916` (see handoff for the exact HEAD).
Gate: `apps/ios/Scripts/build90_recovery_gate.py`, wired into
`apps/ios/Scripts/verify_build91_entitlement_contract.py`
Artifact it reads: `apps/ios/AppStore/build91_release_readiness.json` (currently
`"status": "unresolved"`, both evidence forms `supplied: false`)

Current output, reproduced at this candidate:

```
build90-recovery-gate: NOT READY (fail closed)
  - build-90 charged-before-upgrade prerequisite UNRESOLVED: supply either
    checkout-disabled provider/TestFlight evidence or an owner-approved
    bounded recovery policy (in build91_release_readiness.json or via
    TONO_BUILD90_RECOVERY_EVIDENCE)
```

---

## 1. What the gate is actually protecting

Build 91+ grants a StoreKit entitlement only **after** the user upgrades and the
client uploads its signed transaction. An immutable build-90 client that was
**charged but never upgrades** can therefore never present proof, and the server
can never claim its purchase. The repository cannot prove, from source, whether
any such user exists — that is an external fact about the App Store.

So the gate demands exactly one of two external facts. They are mutually
sufficient: **one complete form flips it to READY.**

## 2. Why the release session did not resolve it

- It is an owner decision about **real users and real money**. Self-approving it
  would be fabricating evidence, which the gate explicitly forbids
  (`_charged_policy_valid` rejects `supplied: true` without corroborating fields).
- Evidence form (a) needs an App Store Connect observation. ASC API **private
  keys are present** on this machine
  (`~/.appstoreconnect/private_keys/AuthKey_6Z71JJSDXE2S.p8`,
  `AuthKey_PSS5YP9VS4.p8`) but **no issuer ID is available** in the environment,
  the repo, or any fastlane config — `apps/ios/fastlane/Fastfile` wires no
  `app_store_connect_api_key`. A read-only ASC query was therefore **not
  possible**; no guess was attempted.

## 3. Choose ONE

### Option A — checkout-disabled evidence (preferred when true)

Use this if build 90 can no longer initiate a purchase for anyone: e.g. the
TestFlight build is expired/removed, or the build is no longer distributed to
any tester or customer.

How to establish it: in App Store Connect → TestFlight (and, if build 90 ever
reached the App Store, → App Store → Version History), confirm build 90 is
expired / removed / superseded and cannot be installed or launched into checkout
by any remaining tester.

Then fill **every** field (all four are required; empty strings are rejected):

```json
"checkout_disabled": {
  "supplied": true,
  "source": "<e.g. App Store Connect TestFlight build 90 state>",
  "verified_by": "<person who looked, e.g. Dov Ginsburg>",
  "verified_at": "<ISO-8601 UTC, e.g. 2026-07-25T14:00:00Z>",
  "reference": "<permalink / screenshot path / ASC build id>"
}
```

### Option B — owner-approved bounded recovery policy

Use this if build 90 **can** still charge, or if that cannot be confirmed. You
are committing to a bounded make-good for anyone charged before upgrading.

Required fields — `bounded_window_days` must be a **positive integer**, and
`owner_approved` must be **true**:

```json
"charged_before_upgrade_policy": {
  "supplied": true,
  "owner_approved": true,
  "approved_by": "<Dov Ginsburg>",
  "approved_at": "<ISO-8601 UTC>",
  "bounded_window_days": <positive integer, e.g. 90>,
  "policy_reference": "<link to the written policy / support macro>"
}
```

### Affected users, if Option B

Anyone who purchased on build 90 and has not upgraded. **The exact count is not
knowable from this repository** — it requires an App Store Connect sales/subscriber
report or a Stripe/Apple reconciliation export. Establish the number before
choosing a window; do not pick a window to fit an assumed count.

## 4. How to supply it

Either edit `apps/ios/AppStore/build91_release_readiness.json` in place and
commit, **or** — preferred, so real evidence need not be committed — write the
same `evidence` object to a file outside the repo and point the gate at it:

```bash
export TONO_BUILD90_RECOVERY_EVIDENCE=/absolute/path/to/build90-evidence.json
```

A set-but-unreadable path fails closed rather than being ignored.

## 5. Verify (must print READY before any store upload)

```bash
cd apps/ios
python3 Scripts/build90_recovery_gate.py            # expect: READY
python3 Scripts/verify_build91_entitlement_contract.py   # expect: PASS
```

Both currently exit non-zero. Do not proceed to codesign/upload until both pass.

## 6. Rollback

Supplying evidence is additive and reversible: revert the JSON edit, or unset
`TONO_BUILD90_RECOVERY_EVIDENCE`, and the gate returns to fail-closed on the
next run. No provider, billing, or customer state is touched by resolving it.

## 7. Do not

- Do not set `supplied: true` with placeholder or invented field values — the
  gate rejects incomplete forms, and a *complete but false* form would defeat the
  only protection standing between a charged build-90 user and silent loss.
- Do not weaken, skip, or unwire the gate to make a release pass.
