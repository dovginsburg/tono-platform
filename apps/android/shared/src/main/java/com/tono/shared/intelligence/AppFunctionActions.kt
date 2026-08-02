package com.tono.shared.intelligence

// Pure decision logic for the three App Function equivalents the product owner
// named: Coach Text, Open Keyboard Setup, and Set Tone Variant. Android mirror
// of how iOS keeps the DECISION in a pure type (`ToneVariantConfiguration.apply`,
// `ShortcutRewrite.resolve`) and the `@AppIntent`/`@AppFunction` wrapper thin.
//
// Pure Kotlin: no AppFunctions library, no annotations, no network, no Android
// framework. Every path is unit-testable on a plain JVM. The quarantined EAP
// service (app/src/appFunctionsEap/, compiled only behind `tono.appfunctions.eap`)
// is a thin wrapper that delegates here — so the meaningful, security-relevant
// behavior is PROVEN even though the annotated surface is not compiled into the
// checked-in build.
//
// AUTHORIZED AND FAIL-CLOSED, BY CONSTRUCTION:
//   • These functions read ONLY their explicit parameters. There is no path to
//     the clipboard, the focused text field, on-screen content, or message
//     history — an agent can only act on text it explicitly passes in.
//   • Coach Text is a GATE, not a sender: it decides whether a request is
//     allowed (registered + entitled) and returns the vetted text to hand to the
//     existing backend path. It never itself performs a background send.
//   • Open Keyboard Setup and Set Tone Variant are entirely local: no text, no
//     network, no account.
//   • None of these can grant Pro, change billing, or override the Safer route.

// MARK: - Open Keyboard Setup (local navigation only)

object OpenKeyboardSetupAction {
    /** The honest result — a route was queued for the host app to present once. */
    data class Result(val route: AppFunctionRoute, val message: String)

    /**
     * Queue the one-shot keyboard-setup route. Carries a route enum only; no
     * text, no payload. The host app presents the screen on its next foreground.
     */
    fun perform(signal: AppFunctionRouteSignalWriter = DefaultRouteSignalWriter): Result {
        signal.request(AppFunctionRoute.KEYBOARD_SETUP)
        return Result(
            route = AppFunctionRoute.KEYBOARD_SETUP,
            message = "Opening Tono keyboard setup.",
        )
    }
}

/** Seam so the route write is injectable in tests without SharedStore. */
interface AppFunctionRouteSignalWriter {
    fun request(route: AppFunctionRoute)
}

object DefaultRouteSignalWriter : AppFunctionRouteSignalWriter {
    override fun request(route: AppFunctionRoute) = AppFunctionRouteSignal.request(route)
}

// MARK: - Coach Text (a gate, never a silent sender)

object CoachTextAction {
    /**
     * The decision for a "Coach this text" request. `Authorized` carries the
     * trimmed text the caller may hand to the existing, gated backend Coach
     * path; every refusal is a distinct, honest reason. The source text is
     * always exactly what the agent explicitly passed — never read from the
     * screen, clipboard, or a message.
     */
    sealed class Outcome {
        data class Authorized(val text: String) : Outcome()
        object EmptyInput : Outcome()
        object NotRegistered : Outcome()
        object EntitlementRequired : Outcome()

        val message: String
            get() = when (this) {
                is Authorized       -> "Coaching your message."
                EmptyInput          -> "Type a message to coach first."
                NotRegistered       -> "Open Tono once to create your account, then try again."
                EntitlementRequired -> "An active trial or subscription is required. Open Tono to continue."
            }

        /** Whether the caller may proceed to the (still gated) backend path. */
        val isAuthorized: Boolean get() = this is Authorized
    }

    /**
     * Decide whether a Coach Text request may proceed. Pure: it authorizes or
     * refuses; it does NOT perform the network call. The annotated wrapper runs
     * the existing backend Coach path ONLY when this returns [Outcome.Authorized],
     * preserving the same account/entitlement gates the keyboard already uses.
     *
     * @param text the text the agent explicitly passed (never read ambiently).
     * @param isRegistered whether this device holds a bearer credential.
     * @param isPro the cached, server-authoritative entitlement mirror.
     */
    fun authorize(text: String, isRegistered: Boolean, isPro: Boolean): Outcome {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return Outcome.EmptyInput
        if (!isRegistered) return Outcome.NotRegistered
        // The backend is the final authority (fails closed with HTTP 402); this
        // pre-gate refuses early when the cached mirror already says not-entitled,
        // so an agent is told the truth rather than triggering a doomed request.
        if (!isPro) return Outcome.EntitlementRequired
        return Outcome.Authorized(trimmed)
    }
}

// MARK: - Set Tone Variant (local preference only)

object ToneVariantAction {
    /**
     * The only "tone variant" a Tono Android agent can toggle locally is the
     * on-device Funnier route's own preference — there is no other user-facing
     * per-tone on/off store on Android, and inventing one an agent could flip
     * would be a fabricated surface. So this maps a request onto
     * [GeminiRewritePreference], honestly and locally.
     */
    sealed class Outcome {
        data class Set(val preference: GeminiRewritePreference) : Outcome()
        data class Unchanged(val preference: GeminiRewritePreference) : Outcome()
        object UnknownVariant : Outcome()

        val didChange: Boolean get() = this is Set

        val message: String
            get() = when (this) {
                is Set -> when (preference) {
                    GeminiRewritePreference.ON            -> "Turned on on-device Funnier."
                    GeminiRewritePreference.ONLY_ON_DEVICE -> "On-device Funnier is on, and only on-device."
                    GeminiRewritePreference.OFF           -> "Turned off on-device Funnier."
                    GeminiRewritePreference.UNSET         -> "On-device Funnier reset to default."
                }
                is Unchanged -> "That was already set."
                UnknownVariant -> "That isn't a tone you can turn on or off here."
            }
    }

    /** The one variant name this action recognises. */
    const val ON_DEVICE_FUNNIER = "on_device_funnier"

    /**
     * Apply an enable/disable request to the current on-device preference. Pure:
     * returns the (possibly unchanged) preference and an honest outcome. The
     * caller persists only when `outcome.didChange`.
     */
    fun apply(variant: String, enable: Boolean, current: GeminiRewritePreference): Outcome {
        if (variant.lowercase().trim() != ON_DEVICE_FUNNIER) return Outcome.UnknownVariant
        val target = if (enable) {
            // Never silently WIDEN an on-device-only choice into "cloud is fine".
            if (current == GeminiRewritePreference.ONLY_ON_DEVICE) GeminiRewritePreference.ONLY_ON_DEVICE
            else GeminiRewritePreference.ON
        } else {
            GeminiRewritePreference.OFF
        }
        return if (target == current) Outcome.Unchanged(current) else Outcome.Set(target)
    }
}
