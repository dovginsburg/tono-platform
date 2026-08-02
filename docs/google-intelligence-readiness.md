# Tono (Android) — Google-intelligence readiness

Android counterpart to `docs/apple-intelligence-readiness.md`. Scope: **App
Functions** equivalents (Coach Text, Open Keyboard Setup, Set Tone Variant) as a
fail-closed, default-off seam, and a compile-tested **ML Kit GenAI (Gemini Nano)
on-device rewrite provider** for a low-risk on-device *Funnier* alternate, behind
a pure routing seam. Tono Android only. No merge, push to `main`, deploy, Play
upload, provider mutation, billing change, secret, or version-code change was
made.

Baseline: `HEAD e8216f1` (branch `claude/tono-google-intelligence-opus48-20260802`).
Toolchain: **AGP 8.2.2, Kotlin 1.9.22, JDK 21**, Android SDK platforms 34/35/36,
build-tools 34/35. Google docs consulted 2026-08-02 (see *Sources*).

## Audit of the shipping app (unchanged facts)

- Modules: `:app` (host, `applicationId com.tono.myapp`, compileSdk 35,
  **minSdk 26**, versionCode 120), `:ime` (keyboard `InputMethodService`), `:shared`.
- Privacy posture today: the keyboard reads the field only inside
  `TonoImeService` (secure fields short-circuit; `onStartInput` bails on password
  variations). Coach/Read are **explicit taps**; rewrites route through
  `CoachViewModel` → `TonoBackend.analyze` (server-authoritative, fails closed
  with HTTP 402 — there is no free tier). This change does not alter any of that.

## What was added

| File | Module / set | Purpose |
|------|--------------|---------|
| `shared/.../intelligence/GeminiRewriteProvider.kt` | :shared (pure) | `RewriteProviderKind` (on-device / backend) + `GeminiRewriteRouter` — pure, total routing seam. No fan-out, fail-closed. Mirror of iOS `RewriteProvider.swift`. |
| `shared/.../intelligence/GeminiNanoAvailability.kt` | :shared (pure) | `GeminiNanoAvailability` (flattens ML Kit `FeatureStatus`), quad-state `GeminiRewritePreference` (+ store & pure helpers), `GeminiRewriteUnavailableReason`, and the `OnDeviceRewriteEngine` interface. Mirror of iOS `LocalCoachRewrite.swift` enums. |
| `shared/.../intelligence/OnDeviceRewriteGuard.kt` | :shared (pure) | The "distinct, non-empty, never the source draft" output guard. Mirror of iOS `ShortcutRewrite.resolve`. |
| `shared/.../intelligence/OnDeviceFunnierUseCase.kt` | :shared (pure) | The one explicit gesture: availability-gate → router → at-most-one generation. Deterministic decline copy. No backend call, no prefetch. |
| `shared/.../intelligence/AppFunctionSeam.kt` | :shared (pure) | Fail-closed `AppFunctionGate` (→ `DISABLED_BY_BUILD` on this build), `AppFunctionRoute` + one-shot `AppFunctionRouteSignal`. Mirror of iOS `PrivateCloudCompute.swift` (fail-closed) + `AppIntentRouting.swift`. |
| `shared/.../intelligence/AppFunctionActions.kt` | :shared (pure) | Pure decision logic for the three App Function equivalents; the annotated wrapper delegates here. |
| `shared/.../flags/FeatureFlags.kt` (edit) | :shared | Adds `GEMINI_NANO_REWRITE` kill switch — **default OFF**, Pro-gated, user-controllable. |
| `ime/.../intelligence/GeminiNanoRewriter.kt` | :ime | The ONLY ML Kit importer: wraps `Rewriter` (checkFeatureStatus / downloadFeature / runInference) with cancellation + timeout + close. Mirror of iOS `AppleRewriteBridge`. |
| `ime/.../CoachViewModel.kt` (edit) | :ime | Thin caller: injects the engine, exposes the explicit on-device Funnier gesture as `OnDeviceFunnierUiState`. Existing Coach/Read flow untouched. |
| `ime/.../ui/KeyboardScreen.kt` (edit) | :ime | Additive `OnDeviceFunnierSection` in Coach results (idle / running+cancel / ready+insert / unavailable+download). |
| `ime/.../TonoImeService.kt` (edit) | :ime | Constructs + attaches + closes the engine. |
| `app/.../MainActivity.kt` (edit) | :app | Consumes the one-shot `AppFunctionRoute` on `onResume` (mirror of the iOS `TonoApp` foreground hook). |
| `app/src/appFunctionsEap/java/.../TonoAppFunctions.kt` | :app (**quarantined**) | The real `@AppFunction` service. Compiled ONLY behind `-Ptono.appfunctions.eap=true` (never in the checked-in build). Analogue of iOS `#if TONO_PCC_XCODE27`. |
| `app/build.gradle.kts` (edit) | :app | The EAP source-set gate (default off) + `-Xskip-metadata-version-check`. |
| `ime/build.gradle.kts` (edit) | :ime | compileSdk 34→35, `genai-rewriting:1.0.0-beta1`, `-Xskip-metadata-version-check`. |
| `shared/.../test/.../intelligence/*` | :shared test | 59 JVM unit tests + the executable `GoogleIntelligenceReadinessVerifier` (55 internal checks). |
| `app/src/androidTest/.../GeminiNanoRewriterInstrumentedTest.kt` | :app androidTest | Device-side fail-closed checks + the ML Kit `FeatureStatus`-constant guard (compiled here; requires a device to run). |

## Acceptance matrix (each state reported separately)

| State | Status | Evidence |
|-------|--------|----------|
| **SOURCE_IMPLEMENTED** | ✅ YES | All files compile. `:shared` + `:ime` + `:app` debug compile; release Kotlin compiles for all three; `:app:minifyReleaseWithR8` (R8) succeeds with ML Kit on the classpath; `:app:lintDebug` clean. |
| **UNIT_TESTS_GREEN** | ✅ YES | `:shared:testDebugUnitTest` = 59 new intelligence tests pass (router 19, availability 10, guard 5, use-case 10, app-functions 14, verifier 1). Verifier prints `55 checks, 0 failures`. Pre-existing account/promo suites unchanged. |
| **DEBUG_APK_BUILT** | ✅ YES | `assembleDebug` produces the app debug APK (bundles `:ime` + `:shared`, incl. the ML Kit boundary). |
| **RELEASE_SIGNED** | ⬜ NO — no secrets | The release `signingConfig` needs `keystore.properties` + `../tono-release.keystore`, which are gitignored/absent (the task forbids touching secrets). Release **compiles** and **R8-minifies**; only the final signing step is unavailable here. |
| **APPFUNCTIONS_ENABLED** | ⬜ NO — intentional, fail-closed | `AppFunctionGate.currentBuildAvailability(...) == DISABLED_BY_BUILD`. App Functions needs Android 16 / compileSdk 36, the `androidx.appfunctions` **alpha** + a KSP compiler requiring **Kotlin 2.x**, and — decisively — **EAP admission**: "As of May 2026, AppFunctions integration with Gemini is in a private preview with trusted testers." The contract is not met, so the annotated service is quarantined and the seam fails closed. `-Ptono.appfunctions.eap=true` proves the gate is real: it includes the source and fails on `Unresolved reference: appfunctions`. **No claim is made that Gemini can invoke Tono's functions end-to-end.** |
| **ON_DEVICE_GENERATION (DEVICE_VERIFIED)** | ⬜ NOT VERIFIED | No physical AICore/Gemini Nano device. The boundary is compile-verified against `genai-rewriting:1.0.0-beta1`; on hardware without AICore it **fails closed** (asserted by the instrumented test, which requires a device to run). No real on-device rewrite was produced in this task. |
| **GESTURE_WIRED** | ✅ YES (source) | The explicit on-device Funnier affordance is wired end-to-end in `CoachViewModel` + `KeyboardScreen`, gated by the default-OFF Pro kill switch **and** a real availability check. It is invisible/inert unless the flag is on AND the device reports the model available. |

## Privacy / safety decisions

- **On-device only, nothing leaves.** `RewriteProviderKind.GEMINI_NANO_ON_DEVICE.leavesDevice == false`; ML Kit GenAI Rewriting runs on Gemini Nano via AICore. The backend path is unchanged and still the only thing that transmits text.
- **No silent reads / no background send.** The App Function equivalents read ONLY their explicit parameters — never clipboard, focused field, screen content, or message history. Coach Text is a GATE (registered + entitled) that returns vetted text; the network call stays the existing entitlement-gated backend path. Open Keyboard Setup / Set Tone Variant are entirely local.
- **Safer stays on the proven backend** unless the corpus gate is explicitly open. **Funnier is the low-risk on-device spike** (the only default axis allowed to lead on-device).
- **No fan-out / no prefetch.** A route plan is one primary + an ordered fallback chain tried one at a time; the use case runs one availability check + at most one generation and never calls the backend itself. Backend fallback is the user's separate explicit tap on the existing Funnier chip.
- **AI cannot override billing/account/safety.** The kill switch is Pro-gated; nothing here grants Pro, changes billing, or bypasses the Safer route or the server's 402.
- **Fail-closed everywhere.** Kill switch off, opt-out, unavailable/downloadable model, offline, or an empty/no-op result all resolve to a named reason with deterministic copy.

## Device limits & terms (ML Kit GenAI, Google docs)

- **Availability:** API 26+, requires the **AICore** app + **Gemini Nano**; **not** supported on devices with an unlocked bootloader; device-limited hardware (the doc does not publish a device whitelist). Input bounded (~256 tokens). `genai-rewriting` is **beta**.
- **Output types are fixed** — `ELABORATE, EMOJIFY, SHORTEN, FRIENDLY, PROFESSIONAL, REPHRASE`. None is literally "funnier", so Funnier maps to the lowest-risk playful type (**FRIENDLY**); this is explicitly **not** claimed equivalent to Tono's reviewed backend Funnier.
- **GenAI API Terms:** developers must inform users of Google's processing of metrics data; Preview/Experimental services may not be used in production; 18+; no competing-model use. These obligations attach when the feature is enabled for users.

## Exact remaining proof (do not mark verified without it)

1. **On-device generation / DEVICE_VERIFIED.** Run on a physical AICore/Gemini
   Nano device: confirm `checkFeatureStatus()` reaches `AVAILABLE` (downloading
   the model via the explicit affordance if needed) and capture a real,
   distinct on-device Funnier rewrite. Run the instrumented test there.
2. **App Functions EAP.** Get EAP admission; move to Kotlin 2.x + KSP + Android 16
   (compileSdk 36); add `androidx.appfunctions:appfunctions:1.0.0-alpha10` +
   `ksp(appfunctions-compiler:1.0.0-alpha10)`; add the `<service>` manifest entry
   with `BIND_APP_FUNCTION_SERVICE`; build with `-Ptono.appfunctions.eap=true`;
   confirm a system agent can discover and invoke the functions end-to-end.
3. **Release signing.** With the real keystore + `keystore.properties`, produce a
   signed release AAB/APK (RELEASE_SIGNED).

## Sources

- ML Kit GenAI Rewriting — https://developers.google.com/ml-kit/genai/rewriting/android
- `Rewriter` reference — https://developers.google.com/android/reference/com/google/mlkit/genai/rewriting/Rewriter
- ML Kit GenAI API Terms — https://developers.google.com/ml-kit/genai-terms
- AppFunctions overview — https://developer.android.com/ai/appfunctions
- Add the AppFunctions API — https://developer.android.com/ai/appfunctions/add-appfunctions
- appfunctions release notes — https://developer.android.com/jetpack/androidx/releases/appfunctions
