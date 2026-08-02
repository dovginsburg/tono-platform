package com.tono.app.intelligence

// ⚠️ QUARANTINED — EARLY ACCESS PROGRAM INTEGRATION POINT. NOT COMPILED BY DEFAULT.
//
// This file is the Android App Functions surface: the `@AppFunction`-annotated
// equivalents of "Coach Text", "Open Keyboard Setup", and "Set Tone Variant".
// It is the direct analogue of the iOS `App/AppleIntelligenceIntents.swift`
// intents — and, like the iOS PCC Xcode-27 adapter (`#if TONO_PCC_XCODE27`), it
// is deliberately fenced OUT of every compiled source set.
//
// It compiles ONLY when a developer builds with `-Ptono.appfunctions.eap=true`
// AND has completed the manual toolchain steps in
// docs/google-intelligence-readiness.md:
//   • Kotlin 2.x (the appfunctions-compiler KSP processor requires it; this
//     project is on Kotlin 1.9.22).
//   • `androidx.appfunctions:appfunctions:1.0.0-alpha10`
//     + `ksp("androidx.appfunctions:appfunctions-compiler:1.0.0-alpha10")`.
//   • `compileSdk = 36` (Android 16) and the KSP Gradle plugin.
//   • The `<service>` manifest entry with
//     `android:permission="android.permission.BIND_APP_FUNCTION_SERVICE"`.
//   • Admission to Google's App Functions Early Access Program — registering
//     interest does NOT grant it, and until it is granted NO system agent
//     (Gemini included) can invoke these functions end-to-end. Compiling an
//     annotation is NOT the same as a system agent being able to call it.
//
// SAFETY, ENFORCED BY DELEGATION. Every function here is a THIN wrapper that
// delegates its real decision to the pure, unit-tested logic in
// `com.tono.shared.intelligence.AppFunctionActions`. It reads only its explicit
// parameters — never the clipboard, the focused field, screen content, or
// message history — and it can neither grant Pro, change billing, nor override
// the Safer route. Coach Text is a GATE that returns vetted text; the network
// call remains the existing, entitlement-gated backend path and is never a
// background send.
//
// The imports below intentionally reference the alpha `androidx.appfunctions`
// package, which is absent from the default classpath — which is exactly why
// this file lives outside the compiled source sets until the EAP contract is
// genuinely met.

import android.content.Context
import androidx.appfunctions.AppFunction
import androidx.appfunctions.AppFunctionContext
import androidx.appfunctions.AppFunctionService
import androidx.appfunctions.AppFunctionServiceEntryPoint
import com.tono.shared.intelligence.CoachTextAction
import com.tono.shared.intelligence.GeminiRewritePreferenceStore
import com.tono.shared.intelligence.OpenKeyboardSetupAction
import com.tono.shared.intelligence.ToneVariantAction
import com.tono.shared.network.TonoBackend
import com.tono.shared.storage.SecureStore
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore

/**
 * The App Functions service that contributes Tono's functions to the system.
 * Bound by the platform with `BIND_APP_FUNCTION_SERVICE`; callers need
 * `EXECUTE_APP_FUNCTIONS`. Off by default (see the class header).
 */
@AppFunctionServiceEntryPoint(
    serviceName = "TonoAppFunctionService",
    appFunctionXmlFileName = "tono_app_function_service",
)
abstract class TonoAppFunctionService : AppFunctionService() {

    /**
     * Open Tono's keyboard setup screen. Entirely local: queues a one-shot
     * route enum for the host app to present. No text, no network, no account.
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun openKeyboardSetup(appFunctionContext: AppFunctionContext): String {
        return OpenKeyboardSetupAction.perform().message
    }

    /**
     * Coach a message the caller explicitly provides.
     *
     * The text is taken ONLY from [message] — never read from the clipboard,
     * the focused field, or message history. It is authorized by the pure gate
     * (registered + entitled); the actual analysis stays on the existing,
     * entitlement-gated backend path and is never a background send. A refusal
     * returns an honest sentence and performs no network call.
     *
     * @param message the text to coach (explicit parameter, not ambient state).
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun coachText(appFunctionContext: AppFunctionContext, message: String): String {
        val outcome = CoachTextAction.authorize(
            text = message,
            isRegistered = SecureStore.isRegistered(),
            isPro = SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED),
        )
        if (outcome !is CoachTextAction.Outcome.Authorized) return outcome.message
        // Authorized → run the SAME gated backend path the keyboard uses. This
        // is the only place a network call can happen, and only after the gate.
        val analysis = TonoBackend.analyze(text = outcome.text)
        return analysis.perception
    }

    /**
     * Turn Tono's on-device Funnier tone on or off. Entirely local: edits the
     * device-local [GeminiRewritePreferenceStore] only. No text, no network, no
     * account. The only tone variant a Tono agent can toggle on Android.
     *
     * @param variant the variant id (currently only "on_device_funnier").
     * @param enabled whether to turn it on (true) or off (false).
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun setToneVariant(
        appFunctionContext: AppFunctionContext,
        variant: String,
        enabled: Boolean,
    ): String {
        val outcome = ToneVariantAction.apply(
            variant = variant,
            enable = enabled,
            current = GeminiRewritePreferenceStore.load(),
        )
        if (outcome is ToneVariantAction.Outcome.Set) {
            GeminiRewritePreferenceStore.save(outcome.preference)
        }
        return outcome.message
    }

    protected fun appContext(): Context = applicationContext
}
