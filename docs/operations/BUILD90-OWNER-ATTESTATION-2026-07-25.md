# Build-90 charged-before-upgrade gate — owner attestation and closure

**Status: CLOSED via Form B (owner-approved bounded recovery policy) over an
owner-attested empty population.**

Recorded: `2026-07-25T03:22:28Z`
Attesting owner: **Dov Ginsburg**
Artifact updated: `apps/ios/AppStore/build91_release_readiness.json`
Gate: `apps/ios/Scripts/build90_recovery_gate.py` → wired into
`apps/ios/Scripts/verify_build91_entitlement_contract.py`

---

## 1. Owner attestation (as given)

> No one has paid for Tono yet through Stripe, App Store, or Google Play.
> Therefore no charged Build-90 user exists and no historical entitlement
> restoration is required. Close the charged-before-upgrade/build-90 gate through
> the documented no-charged-user/Form B path.

## 2. What the gate was protecting, and why this closes it

Build 91+ can only claim a build-90 StoreKit purchase **after** the user upgrades
and the client uploads signed proof. It cannot protect an immutable build-90
client that was **charged but never upgrades**. The gate therefore demanded one
external fact the repository cannot prove about the outside world.

The owner attests the affected population is **empty**: nobody has paid on any
rail. With zero charged users there is no purchase to strand and nothing to
restore, so the risk the gate exists to bound does not exist. Closure is recorded
through **Form B** (`charged_before_upgrade_policy`) because that is the
documented path for an owner decision; Form A (`checkout_disabled`) is
deliberately left `supplied: false` — see §4.

## 3. Independent evidence — non-contradictory, and what each does *not* prove

Everything below was captured read-only by the release session. **None of it is a
substitute for the attestation; it is corroboration that nothing contradicts it.**

| Observation | Receipt | What it establishes | What it does NOT establish |
|---|---|---|---|
| `api.tonoit.com/health` → `apple_configured: false` | captured twice this session | The production backend has **never** had `TONO_APPLE_ROOT_CA_PEM` set, and `app_store.py` returns **503 when unconfigured** ("we never fake success") — so **no App Store purchase has ever been verified or granted** by our server | Does not prove Apple never *charged* anyone; only that our backend never granted |
| `api.tonoit.com/health` → `google_play_configured: false` | same | Same for Play: `TONO_GOOGLE_SERVICE_ACCOUNT_JSON` unset ⇒ verification 503 ⇒ **no Play purchase ever granted** | Does not prove Google never charged anyone |
| `api.tonoit.com/health` → `stripe_configured: true` | same | Stripe **is** live on production, so a web charge was technically possible | ⇒ the "no Stripe payment" fact rests **solely** on the owner's attestation |
| Catalog `providers.app_store.status = "under-review"` | `packages/contracts/commercial-catalog.v1.json:55` | iOS was never publicly released on the App Store | Does not exclude TestFlight purchases |
| Catalog `providers.google_play.status = "closed-test"` | `packages/contracts/commercial-catalog.v1.json:73` | Android was closed-test only, never public production | Does not exclude closed-test purchases |
| Play alpha `versionCode 14` is DRAFT, never rolled out | prior session state | No Play production rollout occurred | — |

**Net:** every independently verifiable signal is *consistent* with the
attestation, and two of them (Apple and Play verification never configured)
independently establish that **no App Store or Play entitlement was ever granted
by the Tono backend**. The Stripe leg is the one rail that was live and was not
independently checked this session.

## 4. What was deliberately NOT claimed

- **Form A (`checkout_disabled`) is left `supplied: false`.** No App Store Connect
  observation of build 90 was made. ASC private keys exist on the release machine
  (`~/.appstoreconnect/private_keys/AuthKey_6Z71JJSDXE2S.p8`,
  `AuthKey_PSS5YP9VS4.p8`) but **no issuer ID** is available in the environment,
  the repo, or any fastlane config, so a read-only ASC query was impossible. It
  was not attempted, guessed, or simulated.
- **No provider report was queried.** No Stripe, App Store Connect, or Play
  Console API call was made — with credentials or otherwise. External network
  verification required approval unavailable in this non-interactive session, and
  provider credentials were not used.
- **`bounded_window_days = 90` was not stated by the owner.** The gate requires a
  positive integer. Because the attested population is empty, 90 days is recorded
  as a conservative safety-net window that binds **no known user**. Change it
  freely.

## 5. Verification — EXECUTED. Both gate scripts were run against this artifact.

The static determination below was authored before execution was available. Both
scripts have since been **executed** against this exact artifact, in the release
worktree at the closing commit's parent tree, with
`TONO_BUILD90_RECOVERY_EVIDENCE` **unset** (confirmed) so the verdict comes from
the committed artifact and not an out-of-band file:

```
$ python3 apps/ios/Scripts/build90_recovery_gate.py
build90-recovery-gate: READY (evidence via artifact)          # exit 0

$ python3 apps/ios/Scripts/verify_build91_entitlement_contract.py
build91-entitlement-contract: PASS                            # exit 0
```

The recorded run matches the predicted output below **exactly**, including the
`(evidence via artifact)` source attribution. QA should still re-run both before
any store upload, as an independent reproduction rather than a first execution.

### Static determination (retained — now corroborated by the run above)

`build90_recovery_gate.evaluate()` (lines 98–130) consults, in order:

1. `TONO_BUILD90_RECOVERY_EVIDENCE` — **unset** in this environment, so skipped.
2. `artifact.get("evidence")` → `_evaluate_evidence` → `_charged_policy_valid`
   on `charged_before_upgrade_policy`:

| Gate requirement (`_charged_policy_valid`, lines 68–86) | Value now recorded | Satisfied |
|---|---|---|
| `supplied` truthy | `true` | ✅ |
| `owner_approved` truthy | `true` | ✅ |
| `approved_by` non-empty str | `"Dov Ginsburg"` | ✅ |
| `approved_at` non-empty str | `"2026-07-25T03:22:28Z"` | ✅ |
| `policy_reference` non-empty str | this document's path | ✅ |
| `bounded_window_days` positive `int`, not `bool` | `90` | ✅ |

⇒ `reasons` empty ⇒ `_charged_policy_valid` → `True` ⇒ `_evaluate_evidence` →
`True` ⇒ `ReadinessResult(ready=True, source="artifact")`.

Expected output when run:

```
$ python3 apps/ios/Scripts/build90_recovery_gate.py
build90-recovery-gate: READY (evidence via artifact)     # exit 0

$ python3 apps/ios/Scripts/verify_build91_entitlement_contract.py
build91-entitlement-contract: PASS                        # exit 0
```

The build-90 readiness check is the **final** assertion in
`verify_build91_entitlement_contract.py` (lines 190–197), immediately followed by
`print("build91-entitlement-contract: PASS")`. Every earlier assertion in that
file already passed before this change — the only failure reported by the prior
recorded run was the build-90 prerequisite — so flipping readiness is sufficient
for the whole verifier to pass.

**Inertness check:** the gate reads **only** `artifact["evidence"]`. The new
`status` and `resolution` keys are documentation and are never consulted, so they
cannot influence the verdict.

## 6. If the attestation is ever contradicted

If any provider report later shows a build-90 charge:

1. Set `status` back to `"unresolved"` and `charged_before_upgrade_policy.supplied`
   to `false` in `apps/ios/AppStore/build91_release_readiness.json`. The gate
   returns to fail-closed on the next run.
2. Treat the 90-day window as **live** for the affected user(s) and honour it.
3. Re-open this document and record the contradicting evidence.

## 7. Rollback

Purely additive and reversible: `git revert` this commit, or restore the previous
`build91_release_readiness.json`, and the gate fails closed again. **No runtime
code, user record, provider state, billing object, or deployment was touched by
this closure.**

## 8. This closure does not release anything

The build-90 gate is one of several. Still blocked, unchanged by this commit:
Preview-scoped Vercel environment; Render backend Apple/Play/provenance
configuration; stale store artifacts requiring rebuilt archives with bumped build
numbers; physical-device acceptance; live sandbox revenue-loop proof; codesign /
upload / store processing; production deployment and promotion. See
`docs/verification/TONO-RELEASE-EXECUTION-LEDGER-OPUS5.md` §6.
