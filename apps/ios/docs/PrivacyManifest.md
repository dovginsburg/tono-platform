# Privacy manifest — Tono host app (build-90)

`App/PrivacyInfo.xcprivacy` is the Apple privacy manifest for the **host app
target**. It was genuinely absent at base SHA `25b82c9`; this is the first one.

## What it declares, and why

- **`NSPrivacyTracking = false`, empty `NSPrivacyTrackingDomains`.** Tono does no
  cross-app/website tracking and contacts no tracking domains.
- **`NSPrivacyCollectedDataTypes` = empty.** The Live Tone privacy/control lane
  collects nothing: it is on-device `UserDefaults` I/O plus pure logic, with no
  networking. This declaration is scoped to *what this lane adds*.
- **`NSPrivacyAccessedAPITypes`:**
  - `NSPrivacyAccessedAPICategoryUserDefaults` → reason **`1C8F.1`**
    (read/write `UserDefaults` accessible only to the app and its extensions,
    via the `group.com.tonoit.shared` App Group). This is the correct reason for
    App-Group–scoped defaults.
  - `NSPrivacyAccessedAPICategoryActiveKeyboards` → reason **`3EC4.1`**. The host
    app reads `UITextInputMode.activeInputModes` in
    `App/OnboardingEntryPointsView.swift` to detect whether the Tono keyboard is
    enabled. Not used for tracking; never sent off-device.

## Documented uncertainty (do not treat as final)

- The **app-wide App Store Connect data-collection nutrition label** — covering the
  deliberate Coach backend round-trip (`Shared/TonoBackend.swift`, which does send
  the user's draft when they tap Coach) — is a *release/integration* concern and is
  intentionally **not** modeled here. That round-trip may require declaring data
  types (e.g. user content) collected-and-linked; the integration/release lane owns
  that determination. This lane deliberately does not invent those declarations.
- This manifest was authored from source inspection, not from Apple's build-time
  "required reason" report. Before submission, run the App Store Connect privacy
  report and reconcile any additional required-reason APIs surfaced by the full
  app + all extension targets.

## Integration blockers (out of this lane's scope)

1. **Xcode project membership.** `PrivacyInfo.xcprivacy` must be added to the host
   app target's "Copy Bundle Resources" build phase in `Tono.xcodeproj`. Adding the
   file to disk (done here) does not register it with the target.
2. **Extension manifests.** The keyboard, Share, iMessage, and Widget extensions are
   separate bundles. Any that access required-reason APIs (they read the same App
   Group `UserDefaults`) need their own `PrivacyInfo.xcprivacy` with reason `1C8F.1`.
   Producing and wiring those belongs to the integration/release lane.
