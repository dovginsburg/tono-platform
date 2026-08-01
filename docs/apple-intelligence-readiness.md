# Tono — Apple Intelligence readiness

Scope of this change: App Intents (entities-first), a compile-tested Foundation
Models **provider abstraction / routing seam**, and a fail-closed **Private
Cloud Compute (PCC)** seam. Tono only. No merge, push, deploy, upload, provider
mutation, billing change, or build-number change was made.

Baseline: `HEAD 444ad47`, tree `57570f8c`. Toolchain: **Xcode 26.5**, iOS 26.5
SDK only (no iOS 27 / PCC SDK on this machine).

## What was added

| File | Target membership | Purpose |
|------|-------------------|---------|
| `Shared/RewriteProvider.swift` | Tono, TonoKeyboard, TonoShare, TonoMessagesExtension, TonoTests | Provider identity (`RewriteProviderKind`) + pure routing seam (`RewriteProviderRouter`). No fan-out, fail-closed. |
| `Shared/PrivateCloudCompute.swift` | Tono, TonoKeyboard, TonoShare, TonoMessagesExtension, TonoTests | `PCCAvailability` states, probe seam, and the **compile-gated** Xcode-27 adapter (`#if TONO_PCC_XCODE27`, never defined). |
| `Shared/AppIntentRouting.swift` | Tono, TonoTests | One-shot App-Intent → app navigation signal (carries a route enum, never text). |
| `Shared/CoachVariantSettings.swift` (edit) | (existing) | `ToneVariantConfiguration` — pure enable/disable-tone policy. |
| `App/ToneVariantEntity.swift` | Tono | `ToneVariantEntity: AppEntity` + `ToneVariantQuery` (entities-first, privacy-safe id = axis string). |
| `App/AppleIntelligenceIntents.swift` | Tono | `OpenKeyboardSetupIntent`, `SetToneVariantEnabledIntent` (local-only actions). |
| `App/CoachDraftIntent.swift` (edit) | (existing) | `TonoShortcutsProvider` enhanced with the keyboard-setup shortcut; "Coach this text" preserved verbatim. |
| `App/TonoApp.swift` (edit) | (existing) | Contained hook that presents keyboard setup once when the intent requests it. |
| `Scripts/verify_apple_intelligence_routing.swift` | — | Runnable `swiftc` contract test (199 checks). |
| `Scripts/verify_tone_variant_config.swift` | — | Runnable `swiftc` contract test (34 checks). |
| `Tests/Build118AppleIntelligenceTests.swift` | TonoTests | XCTest half (11 tests). |

## Acceptance matrix

Each state is reported separately. **Nothing device-side or PCC-side is marked
verified** — those require hardware and/or a toolchain this machine does not have.

| State | Status | Evidence / why |
|-------|--------|----------------|
| **SOURCE_IMPLEMENTED** | ✅ YES | All files above compile. Verifiers: routing 199/199, tone-variant 34/34; XCTest 11/11; shortcut regression 50/50. |
| **TARGET_REGISTERED** | ✅ YES (source) | The intents/entities/provider files are members of shipping targets and compile into them (`build` + `build-for-testing` SUCCEEDED, Debug **and** Release). `AppShortcutsProvider` (`TonoShortcutsProvider`) is present so the framework auto-registers the intents at install. Runtime registration itself is device-observed (see DEVICE_VERIFIED). |
| **SHORTCUT_DISCOVERABLE** | 🟡 SOURCE ONLY | `TonoShortcutsProvider` declares phrases for "Coach this text" (preserved) and "Open Tono Keyboard Setup" (new). Whether the phrases actually appear in Shortcuts/Siri is observable only on a device — not verified here. |
| **SPOTLIGHT_CONTENT_INDEXED** | ⬜ NO — intentionally | Reported **separately from action discoverability**, as required. **Action/entity discoverability** is via App Intents: `ToneVariantQuery.suggestedEntities()` surfaces the tone variants, and the entity id is the axis string only. **Searchable CONTENT indexing** (`CoreSpotlight` / `CSSearchableItem` over coaching history) is deliberately **not** implemented — no source proves retained coaching history exists whose privacy contract permits indexing, so none is indexed. |
| **FOUNDATION_MODEL_VERIFIED** | ⬜ NOT VERIFIED (this change) | The routing seam is a *decision* layer; it does not itself run a generation. The existing on-device path (`OnDeviceAppleRewrite` / `AppleRewriteBridge`, which calls `SystemLanguageModel`) is unchanged. No new on-device generation was executed in this task. |
| **PCC_ENTITLEMENT_GRANTED** | ⬜ NO | Out of scope and not done. `PCCEntitlement.candidateIdentifier` is a *named unknown*, not a grant; `Tono.entitlements` is unchanged; `PCCEntitlement.isGrantedInThisBuild == false`. |
| **PCC_RUNTIME_VERIFIED** | ⬜ NO | The iOS 26.5 SDK exposes no developer-addressable PCC rewrite API. `DefaultPCCAvailabilityProbe().probe()` returns `.unsupportedOS` (fail-closed). PCC is never selected by the router unless a probe returns `.available`, which cannot happen on this toolchain. |
| **DEVICE_VERIFIED** | ⬜ NO | No physical-device run. All evidence is Simulator build + pure unit tests. |

## Privacy / safety decisions

- **No silent reads or transmission.** The entity and both new actions read no
  message text, no clipboard, and no typed text; they transmit nothing. Network
  generation happens **only** via the explicit `CoachDraftIntent`, which keeps
  its account/entitlement/provider gates.
- **On-device-only forbids PCC too.** `RewriteProviderKind.leavesDevice` is
  `true` for both the backend **and** PCC — PCC is private but off-device — so
  the `.onlyOnDevice` preference removes both, and yields a terminal refusal
  rather than sending anything. Asserted by tests.
- **Safer stays on the proven backend** unless the corpus-quality gate is
  explicitly open. **Funnier is the low-risk on-device Apple spike** (the only
  default axis permitted to lead on-device).
- **No fan-out.** A route plan is a single primary + an ordered fallback chain
  tried one at a time; the type cannot express concurrent generation.
- **Fail-closed everywhere.** Unknown PCC, kill switch off, opt-out, or an
  unavailable model all fall back to the proven backend, or to a terminal
  refusal when the network is forbidden/absent.

## Exact remaining proof (do not mark verified without it)

1. **Xcode 27 / PCC SDK.** Install the first toolchain shipping a
   developer-addressable Private Cloud Compute Foundation Models surface.
   **Confirm the concrete availability symbol exists** (SDK headers / `swift -e`)
   — do **not** guess a name. Fill in `TonoPCCXcode27Adapter.probe()` (behind
   `TONO_PCC_XCODE27`) with that confirmed query and map it to `PCCAvailability`.
2. **PCC entitlement.** Add the real entitlement key (from Apple's PCC docs) to
   `App/Tono.entitlements`, prove it is granted on a physical device
   (PCC_ENTITLEMENT_GRANTED), and prove a real request succeeds end-to-end
   (PCC_RUNTIME_VERIFIED).
3. **On-device generation.** Run the existing on-device path on a physical,
   Apple-Intelligence-capable device and capture a real rewrite
   (FOUNDATION_MODEL_VERIFIED, DEVICE_VERIFIED).
4. **Shortcut/Spotlight discoverability.** On a device, confirm the shortcut
   phrases appear in Shortcuts/Siri and the tone-variant entities appear as
   suggestions (SHORTCUT_DISCOVERABLE at runtime).

## Consult note

The request offered a Fable consult "if needed". None was taken: the
orchestrator constraint makes this worktree single-writer with no subagents, and
the work stayed inside the existing, well-documented invariants. No decision hit
a point where an outside opinion was required.
