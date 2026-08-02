package com.tono.shared.intelligence

import com.tono.shared.models.RewriteAxis

// The one explicit gesture that adopts the Google-intelligence seam: produce a
// lighter, on-device "Funnier" alternate for a draft the user has already
// Coached. Pure Kotlin + coroutines, no Android and no ML Kit imports, so the
// entire flow — availability gating, the router decision, cancellation, the
// no-fan-out guarantee — is unit-testable on a plain JVM by injecting a fake
// [OnDeviceRewriteEngine]. `CoachViewModel` is a thin caller.
//
// INVARIANTS ENFORCED HERE:
//   • Explicit only: runs when a caller invokes [run]; never on a timer, never
//     speculatively.
//   • No fan-out / no prefetch: exactly one availability status-check and, only
//     if the router picks the on-device engine, exactly one generation. The
//     backend is NEVER called from here — the user's fallback is to tap the
//     existing (separate, explicit) backend Funnier chip.
//   • Fail-closed & deterministic: every decline is a named
//     [GeminiRewriteUnavailableReason]; the source draft is never returned as a
//     rewrite (the engine applies [OnDeviceRewriteGuard]).

/** The outcome of one explicit on-device Funnier request. */
sealed class OnDeviceFunnierResult {
    /** A distinct, on-device rewrite the user may choose to insert. */
    data class Rewrote(val text: String) : OnDeviceFunnierResult()

    /** No rewrite was produced; [reason] says exactly why, deterministically. */
    data class Unavailable(val reason: GeminiRewriteUnavailableReason) : OnDeviceFunnierResult()
}

class OnDeviceFunnierUseCase(
    private val router: GeminiRewriteRouter = GeminiRewriteRouter(),
    /** Bound so a stuck on-device generation cannot hang the keyboard. */
    val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
) {
    /**
     * Run the explicit on-device Funnier gesture.
     *
     * @param draft the text the user already Coached.
     * @param engine the on-device engine (injected; a fake in tests).
     * @param remoteKillSwitchAllows the operator kill switch (a feature flag).
     * @param preference the person's own on-device preference.
     * @param connectivityKnownAbsent whether transport proved the network gone.
     */
    suspend fun run(
        draft: String,
        engine: OnDeviceRewriteEngine,
        remoteKillSwitchAllows: Boolean,
        preference: GeminiRewritePreference,
        connectivityKnownAbsent: Boolean = false,
    ): OnDeviceFunnierResult {
        val text = draft.trim()
        if (text.isEmpty()) {
            return OnDeviceFunnierResult.Unavailable(GeminiRewriteUnavailableReason.EMPTY_DRAFT)
        }

        // A status check only — reads the draft locally, sends nothing.
        val availability = engine.availability()

        val decision = router.decide(
            requestedAxis = RewriteAxis.FUNNIER.value,
            remoteKillSwitchAllows = remoteKillSwitchAllows,
            preference = preference,
            onDeviceAvailability = availability,
            saferCorpusGateOpen = false,
            connectivityKnownAbsent = connectivityKnownAbsent,
        )

        // Only the on-device engine may serve this gesture. If the router would
        // lead with the backend (or refuse outright), we surface a deterministic
        // reason rather than silently sending the draft to the network.
        if (decision.primaryProvider != RewriteProviderKind.GEMINI_NANO_ON_DEVICE) {
            val reason = when (decision) {
                is RewriteRoutingDecision.Terminal -> decision.reason
                is RewriteRoutingDecision.Route ->
                    // Router chose the backend: name why the on-device engine
                    // was not eligible (kill switch / opt-out / availability).
                    when {
                        !remoteKillSwitchAllows -> GeminiRewriteUnavailableReason.REMOTE_KILL_SWITCH
                        preference == GeminiRewritePreference.OFF -> GeminiRewriteUnavailableReason.USER_TURNED_OFF
                        else -> GeminiRewriteUnavailableReason.fromAvailability(availability)
                    }
            }
            return OnDeviceFunnierResult.Unavailable(reason)
        }

        // Exactly one generation. Cancellation propagates (the caller cancels the
        // coroutine); timeout is enforced inside the engine.
        return when (val outcome = engine.rewrite(text, RewriteAxis.FUNNIER, timeoutMs)) {
            is OnDeviceRewriteOutcome.Success -> OnDeviceFunnierResult.Rewrote(outcome.text)
            is OnDeviceRewriteOutcome.Failure -> OnDeviceFunnierResult.Unavailable(outcome.reason)
        }
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 8_000L

        /**
         * Deterministic, user-facing copy for each decline reason. Reviewed
         * against the Build 112 consumer-copy contract: no implementation
         * detail, no alarm, and "type more" / "check connection" never share a
         * sentence with an opposite instruction.
         */
        fun message(reason: GeminiRewriteUnavailableReason): String = when (reason) {
            GeminiRewriteUnavailableReason.REMOTE_KILL_SWITCH,
            GeminiRewriteUnavailableReason.USER_TURNED_OFF ->
                "On-device rewrites are turned off."
            GeminiRewriteUnavailableReason.UNSUPPORTED_OS,
            GeminiRewriteUnavailableReason.DEVICE_NOT_ELIGIBLE ->
                "On-device rewrites aren't available on this device. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.MODEL_DOWNLOADABLE ->
                "The on-device model isn't downloaded yet."
            GeminiRewriteUnavailableReason.MODEL_DOWNLOADING ->
                "The on-device model is still downloading. Try again in a moment."
            GeminiRewriteUnavailableReason.MODEL_NOT_READY ->
                "The on-device model isn't ready yet. Try again in a moment."
            GeminiRewriteUnavailableReason.EMPTY_DRAFT ->
                "Type a message first."
            GeminiRewriteUnavailableReason.DRAFT_TOO_LONG ->
                "That message is too long for the on-device model."
            GeminiRewriteUnavailableReason.CANCELLED ->
                "Cancelled."
            GeminiRewriteUnavailableReason.TIMED_OUT ->
                "That took too long on-device. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.DOWNLOAD_FAILED ->
                "Couldn't download the on-device model. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.GUARDRAIL ->
                "The on-device model declined that one. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.GENERATION_FAILED ->
                "The on-device rewrite didn't work. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.NO_VALID_REWRITE ->
                "No distinct on-device rewrite this time. Tap Funnier to use Tono."
            GeminiRewriteUnavailableReason.SAFER_NEEDS_REVIEW ->
                "Safer stays on Tono for review."
            GeminiRewriteUnavailableReason.TONE_NEEDS_CONNECTION,
            GeminiRewriteUnavailableReason.CUSTOM_STYLE_NEEDS_CONNECTION ->
                "That tone needs a connection. Tap Funnier to use Tono."
        }

        /** Whether the decline is one an explicit model download could fix. */
        fun isDownloadable(reason: GeminiRewriteUnavailableReason): Boolean =
            reason == GeminiRewriteUnavailableReason.MODEL_DOWNLOADABLE
    }
}
