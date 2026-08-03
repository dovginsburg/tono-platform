# Tono iOS auth-provider repair — handoff (2026-08-03)

Branch: `claude/tono-email-verification-authority-opus48-20260803`
Scope: Tono only. No sibling product (TandemPaws/TandemSkills/ParentScript) was
touched, referenced, or borrowed from. Bundle id `com.tonoit.app`, team
`4938S9TTBM`, canonical backend `https://api.tonoit.com`, and all existing
RevenueCat work are preserved. Backend stays the sole auth/entitlement authority;
every boundary remains fail-closed.

The user-visible defect: the installed app showed an Apple sign-in button that did
nothing, no Google, no passkeys, and a "resend email" that reported success but
delivered no link. Each is addressed below with Finding / Fix / Verification, then
the provider prerequisites that remain (they are portal/DNS/env steps, not code).

---

## A. Sign in with Apple — the button shipped without the entitlement

**Finding.** `App/OnboardingEntryPointsView.swift` renders `SignInWithAppleButton`
(in `EmailSignInSheet.providerButtons`), but `App/Tono.entitlements` did **not**
contain `com.apple.developer.applesignin`. Without the entitlement the system
refuses the authorization request, so the button was inert on the installed app.
The backend `/v1/auth/apple` is healthy and `/health` reports
`apple_signin_configured=true`, so this was purely a client entitlement gap.

**Fix.**
- Added `com.apple.developer.applesignin = ["Default"]` to `App/Tono.entitlements`.
- Preserved the nonce/audience flow unchanged: the client sets
  `request.nonce = SHA256.hash(rawNonce)` and sends the **raw** nonce to the
  backend, which re-hashes with `hashlib.sha256(body.nonce…).hexdigest()` and
  compares (`server.py:931`). The client sends no audience — the backend's is
  env-driven (`APPLE_CLIENT_ID` = the bundle id).
- Added a guard test that fails if the visible Apple button ever ships again
  without the entitlement beside it
  (`Build124AuthProvidersTests.testAppleButtonRequiresTheSignInWithAppleEntitlement`)
  and one pinning the nonce contract on both client and server.

## B. Google — SDK was not linked; button compiled out

**Finding.** Google was behind `#if canImport(GoogleSignIn)`, and the Xcode project
had **no** GoogleSignIn package, so the branch never compiled and no button
appeared. Making a button appear needs both the SDK linked and Tono's own OAuth
client configured — and the latter must never be a fabricated or sibling value.

**Fix.**
- Linked **GoogleSignIn-iOS 7.1.0** via SPM into the **Tono app target only**
  (added a Frameworks build phase + the package graph to `project.pbxproj`;
  transitive AppAuth 1.7.6 / GTMAppAuth / gtm-session-fetcher 3.5.0 resolve
  automatically).
- Added `App/GoogleSignInConfig.swift`: a fail-closed gate (mirrors the
  RevenueCat kill-switch pattern) reading `GIDClientID` from Info.plist. Empty /
  placeholder / unexpanded build variable ⇒ **not configured**.
- `App/Info.plist` now carries the **contract, not a secret**: `GIDClientID =
  $(GID_CLIENT_ID)` and a `CFBundleURLTypes` scheme of `$(GID_URL_SCHEME)` (the
  reversed client id). Both default empty (fail closed). No sibling identifier or
  secret is embedded anywhere.
- The "Continue with Google" button renders **only** when
  `GoogleSignInConfig.isConfigured` (nested inside `#if canImport(GoogleSignIn)`),
  so an unconfigured build shows no Google affordance rather than a tap target
  that can only fail. `submitGoogle()` also guards on config before touching the
  SDK (GoogleSignIn *raises* rather than returns an error when unconfigured).
- `TonoApp` configures the SDK if possible at launch and routes the OAuth redirect
  via `.onOpenURL { GoogleSignInConfig.handle($0) }` (a no-op unless linked +
  configured).
- Guards in `Build124AuthProvidersTests`: the package is linked; the button is
  gated on linkage **and** real config; the config is fail-closed in this build
  (`isConfigured == false`, `clientID == nil`); and no `apps.googleusercontent.com`
  literal is embedded. The prior Build114 guard that asserted the SDK was *not*
  linked was retired (its own note deferred exactly this review).

## C. Passkeys — no client at all

**Finding.** Production `/v1/auth/passkey/*` ceremonies exist with `rpId =
tonoit.com`, but the iOS app had no passkey client, button, or associated-domains
entitlement.

**Fix.**
- Added `App/PasskeySignIn.swift`: native registration **and** sign-in via
  `AuthenticationServices` (`ASAuthorizationPlatformPublicKeyCredentialProvider`),
  driving the backend ceremonies (`apps/backend/passkeys.py`). base64url at the
  boundary; an `ASAuthorizationController` bridged to async/await with correct
  self-retention.
- Added transport methods to `Shared/TonoBackend.swift`
  (`passkeyRegisterOptions/Verify`, `passkeyLoginOptions/Verify`).
- Added `com.apple.developer.associated-domains = ["webcredentials:tonoit.com"]`
  to `App/Tono.entitlements`. The authoritative rpId is exactly `tonoit.com`;
  `PasskeyConfig.canonicalRelyingPartyID` and the entitlement are asserted to
  match.
- **Never fakes success.** `.signedIn`/`.registered` are returned only after the
  backend `verify` endpoint accepts the assertion; a dismissed sheet is silent; a
  missing AASA/capability surfaces as an honest failure. Because AASA presence is
  not detectable at runtime, the button is gated **OFF by default**
  (`TONO_PASSKEYS_ENABLED`, fail closed) so the app never offers a passkey tap
  target that cannot yet succeed — the ceremony code always compiles and is ready
  the moment an operator provisions the capability + AASA and flips the flag.

## D. Email UX — accepted resend falsely implied delivery

**Finding.** `/v1/auth/email/resend` (and register) return **202** and, by
anti-enumeration design, send **no** mail for an already-confirmed address. The
copy said "Open the link we sent to confirm your address" — a delivery claim that
is false for an already-confirmed account, leaving the user waiting for mail that
never comes.

**Fix (without weakening anti-enumeration).**
- The accepted create/resend message is now conditional and honest, and names the
  exit an already-confirmed person needs: *"If that address still needs
  confirming, we'll email a link — open it, then sign in. If it's already
  confirmed, no new email is sent; just sign in, or use Forgot Password."* It no
  longer claims a link was sent.
- Create and resend remain **identical** (the anti-enumeration invariant Build114
  pins), so the sheet still cannot distinguish a known from an unknown address.
  Unifying them also fixed a latent false-delivery claim in the create path.
- Password reset is kept **separate and truthful**: *"If we can reset that
  address, we'll email a link to choose a new password…"* — conditional, never a
  flat delivery claim.
- The `confirmSent` follow-up text is likewise conditional ("If a link
  arrives…"). New guards in `Build124AuthProvidersTests` forbid any unconditional
  delivery phrase in the accepted copy and require the sign-in / Forgot-Password
  exits.

## E. One canonical account + fail-closed paid access

**Finding.** Apple/Google already converged on the canonical `account_id`
server-side, but the client wrote the purchase-gating `signedInEmail` key in **two**
places (`signInWithEmail` and `signInWithNativeProvider`) — a latent regression:
Build114's `testTheConfirmedAddressIsWrittenInExactlyOnePlace` asserts exactly one
writer, so that test was already red on this tree.

**Fix.**
- Funnelled every verified-identity write through one private helper
  (`setSignedInEmail`) and one convergence helper (`persistProviderConvergence`,
  which sets `accountID` + `hasRecoveryIdentity` + the address). Email, Apple,
  Google and passkey now all converge through the same single writer — restoring
  the exactly-one-writer invariant (Build114 green again) and giving passkey the
  same convergence as the other providers.
- Paid access stays fail-closed: `StoreKitManager.isIdentifiedAccount` still
  requires the canonical `accountID` and returns false without it. Confirming an
  address (any provider) is a precondition for buying, never a grant of Pro; the
  backend `/v1/me` projection remains the sole Pro authority.

---

## Verification — exact commands and results

All from `apps/ios/` unless noted. Xcode 26.5 (17F42), iOS 26.5 SDK/sim.

1. **Baseline compile (before changes)** — `BUILD SUCCEEDED`.
   `xcodebuild build -scheme Tono -destination 'generic/platform=iOS Simulator' -derivedDataPath … CODE_SIGNING_ALLOWED=NO`
2. **SPM resolution** — `GoogleSignIn-iOS 7.1.0`, `AppAuth-iOS 1.7.6`,
   `GTMAppAuth`, `gtm-session-fetcher 3.5.0` fetched + checked out.
3. **Real compile with GoogleSignIn linked** — `BUILD SUCCEEDED` (exit 0). The
   `canImport(GoogleSignIn)` branch now compiles against the real SDK; all new
   files compile.
4. **Full iOS test suite (signed, TonoTests, iPhone 16 / iOS 26.5)** — **Executed
   945 tests, 4 failures** on the first run; **all 16 new
   `Build124AuthProvidersTests` passed**, and every other auth/account test
   (Build96 coach-auth, Build114 email-account) passed. Of the 4 failures, one
   (`Build114…testTheConfirmedAddressIsWrittenInExactlyOnePlace`) was a latent
   pre-existing red I diagnosed and fixed as part of this work (see below); the
   remaining **3 are pre-existing on this tree and unrelated to auth** (proof
   below). After the fix a targeted re-run of Build114 + Build124 is green.
   `xcodebuild test -scheme Tono -destination 'platform=iOS Simulator,id=<sim>' -only-testing:TonoTests DEVELOPMENT_TEAM=4938S9TTBM`
   New: `Build124AuthProvidersTests` (A/B/C/D/E guards). Retired the obsolete
   Google guard in `Build114EmailAccountTests`.

   **Pre-existing failures NOT caused by this change (3).** Each scans a file this
   change never touches (`git diff --name-only HEAD` does not list any of them),
   so each fails identically on the base tree; all three are the exact residuals
   the iOS notes record as fixed only on a *different* branch (391b51d), not on
   this RevenueCat lineage (c125a18):
   - `Build112UISurfaceContractTests.testTheFailureMapperIsPinnedClassifiesByCaseAndShipsEverywhere`
     — a payment-history sentence in `ConsumerErrorCopy` (untouched).
   - `Build115IPadSurfaceLayoutTests.testNoNewControlFallsBelowTheTouchTargetGuideline`
     — the pre-existing "Show password" reveal control in the password field
     (untouched; my added controls are not flagged).
   - `Build116SelectedFirstTests.testNoUserVisibleCopyNamesASpecificDeviceFamily`
     — an "Android phone" line in `SettingsView` (untouched).

   **The one I fixed (in scope for part E).**
   `Build114EmailAccountTests.testTheConfirmedAddressIsWrittenInExactlyOnePlaceAndOnlyOnServerProof`
   was doubly red on the base tree: (a) two writers of `signedInEmail`
   (`signInWithEmail` + `signInWithNativeProvider`) failed its exactly-one-writer
   assertion, and (b) its "no other file writes it" sweep false-positived on
   `StoreKitManager` (which READS `signedInEmail` and WRITES the different
   `hasRecoveryIdentity`). (a) is fixed by the single-writer refactor; (b) by
   making the sweep match the actual write form `forKey: KeychainKeys.signedInEmail`
   instead of three separately-landing substrings. Both are part-E correctness.
5. **Backend auth contract tests** — **172 passed, 0 failed** (no backend code
   changed; this proves the ceremonies the client targets are intact).
   `python3 -m pytest tests/test_passkeys.py tests/test_apple_web_auth.py tests/test_email_verification_authority.py tests/test_account_continuity.py tests/test_accounts.py tests/test_email_account_entitlement.py tests/test_web_auth.py tests/test_email_accounts.py tests/test_apple_signin_health_flag.py -q`
6. **pbxproj integrity** — `plutil -lint` OK; `xcodebuild -list` parses.

## Changed files

- `App/Tono.entitlements` — + `com.apple.developer.applesignin`,
  + `com.apple.developer.associated-domains` (`webcredentials:tonoit.com`).
- `App/OnboardingEntryPointsView.swift` — honest email copy (D); Google button
  gated on real config; passkey sign-in/registration buttons + `submitPasskey`.
- `App/GoogleSignInConfig.swift` — **new**, Google fail-closed config gate.
- `App/PasskeySignIn.swift` — **new**, AuthenticationServices passkey client.
- `App/TonoApp.swift` — Google configure-at-launch + `onOpenURL` redirect handler.
- `App/Info.plist` — `GIDClientID`/URL-scheme build-variable contract;
  `TONO_PASSKEYS_ENABLED`, `TONO_WEBAUTHN_RP_ID` (all empty/fail-closed).
- `Shared/TonoBackend.swift` — passkey transport methods; single-writer
  `setSignedInEmail` + `persistProviderConvergence`.
- `Tests/Build124AuthProvidersTests.swift` — **new**, A/B/C/D/E guard tests.
- `Tests/Build114EmailAccountTests.swift` — retired the now-false Google guard.
- `Tono.xcodeproj/project.pbxproj` — link GoogleSignIn-iOS SPM into the app
  target; wire the two new App files + the new test file.

---

## Remaining provider blockers (portal / DNS / env — not code)

These gate real-device/provider success. Nothing below can be done from source,
and none of it should be faked. Do **not** upload a TestFlight/device build until
the relevant ones are satisfied — a signed device build will otherwise fail to
sign (the new capabilities must be on the App ID) or ship a dormant provider.

- **Apple (unblocks A):** enable **Sign in with Apple** on App ID
  `4938S9TTBM.com.tonoit.app` in the Developer portal; regenerate the provisioning
  profile so a signed build carries `com.apple.developer.applesignin`. Confirm
  backend `APPLE_CLIENT_ID = com.tonoit.app` (health already reports
  `apple_signin_configured=true`).
- **Google (unblocks B):** (1) create a Tono **iOS OAuth client** in Google Cloud
  → obtain the client id and its reversed form; (2) set backend `GOOGLE_CLIENT_ID`
  (the audience the `social_auth` google verifier checks) to include that client
  id; (3) set build settings `GID_CLIENT_ID` and `GID_URL_SCHEME`. The button then
  appears and works. Until then it is fail-closed (no button).
- **Passkey (unblocks C):** (1) enable **Associated Domains** + **Sign in with
  Apple** capabilities on the App ID; (2) host the AASA at
  `https://tonoit.com/.well-known/apple-app-site-association` (served as
  `application/json`, no redirect) with a `webcredentials` section listing
  `4938S9TTBM.com.tonoit.app`; (3) set backend `WEBAUTHN_RP_ID=tonoit.com` and
  `WEBAUTHN_ORIGIN=https://tonoit.com` (Apple reports origin `https://<rpId>` for a
  native ceremony); (4) set build setting `TONO_PASSKEYS_ENABLED=YES`. Until then
  fail-closed (no button); the ceremony is implemented and the entitlement is in
  source.
- **Email (D):** no provider blocker. The "no mail for an already-confirmed
  address" behavior is by design (anti-enumeration) and is now surfaced honestly.

## Build / release instructions

- **Compile (no signing):**
  `xcodebuild build -project Tono.xcodeproj -scheme Tono -destination 'generic/platform=iOS Simulator' -clonedSourcePackagesDirPath <spm-cache> CODE_SIGNING_ALLOWED=NO`
- **Test (signed simulator):**
  `xcodebuild test -project Tono.xcodeproj -scheme Tono -destination 'platform=iOS Simulator,id=<sim-udid>' -only-testing:TonoTests DEVELOPMENT_TEAM=4938S9TTBM`
- **Device / TestFlight:** requires the Apple + Associated Domains capabilities on
  the App ID (above); confirm a free `CFBundleVersion` on App Store Connect before
  archiving (prior build numbers are consumed — see the iOS build-lane notes). This
  change set is **source-complete and provider-gated**; it is not authorized for
  upload here and none of the provider prerequisites are assumed satisfied.
