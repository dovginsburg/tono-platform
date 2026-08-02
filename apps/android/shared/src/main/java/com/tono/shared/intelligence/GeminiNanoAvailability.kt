package com.tono.shared.intelligence

import com.tono.shared.storage.SharedStore

// Google-intelligence readiness — the on-device availability, preference, and
// refusal vocabulary. Android mirror of the `LocalRewriteAvailability` /
// `LocalRewritePreference` / `LocalCoachUnavailableReason` types in
// ios/Shared/LocalCoachRewrite.swift.
//
// Pure Kotlin. Nothing here imports ML Kit or touches AICore: the ML Kit
// `FeatureStatus` integer is flattened into [GeminiNanoAvailability] by the ONE
// boundary that links ML Kit (`:ime` GeminiNanoRewriter), so the router, the
// preference store, and every unit test can run on a plain JVM with no device.

// MARK: - Availability (fail-closed)

/**
 * What the on-device Gemini Nano model reports about itself, flattened into a
 * value the rest of the app can hold without importing ML Kit.
 *
 * The first four cases map one-to-one onto ML Kit's `FeatureStatus`
 * (`UNAVAILABLE`, `DOWNLOADABLE`, `DOWNLOADING`, `AVAILABLE`); the last two are
 * ours, not ML Kit's — the OS/AICore floor and a catch-all. Only [AVAILABLE]
 * is usable this instant; everything else is a distinct, honest reason. There
 * is no "unknown = maybe yes" state, because the whole contract is fail-closed.
 */
enum class GeminiNanoAvailability(val reasonCode: String) {
    /** ML Kit `FeatureStatus.AVAILABLE`: model present, ready, usable now. */
    AVAILABLE("available"),

    /**
     * ML Kit `FeatureStatus.DOWNLOADABLE`: the device supports Gemini Nano but
     * the model assets are not on the device yet. Reachable only by an explicit
     * user-triggered download — never a silent/background fetch.
     */
    DOWNLOADABLE("downloadable"),

    /** ML Kit `FeatureStatus.DOWNLOADING`: assets are being fetched right now. */
    DOWNLOADING("downloading"),

    /**
     * ML Kit `FeatureStatus.UNAVAILABLE`: this device cannot run the feature —
     * no AICore, no Gemini Nano, an unlocked bootloader, or unsupported
     * hardware. Fail-closed: treated as permanently not-available.
     */
    DEVICE_NOT_ELIGIBLE("device_not_eligible"),

    /**
     * Below the OS/SDK floor, or ML Kit GenAI was not linkable in this build.
     * ML Kit GenAI requires API 26+; this build's `minSdk` is also 26, so this
     * is mostly a future-proofing case, but it is named so a floor change can
     * never silently land on a wrong sentence.
     */
    UNSUPPORTED_OS("unsupported_os"),

    /** Not yet probed, or a status ML Kit reports that this build does not know. */
    UNSPECIFIED_UNAVAILABLE("unspecified_unavailable");

    /** The single gate. Only an explicit [AVAILABLE] counts as usable now. */
    val isAvailable: Boolean get() = this == AVAILABLE

    /** Whether an explicit user download could make the model available. */
    val isDownloadable: Boolean get() = this == DOWNLOADABLE

    /** Whether a download is already in flight. */
    val isDownloading: Boolean get() = this == DOWNLOADING

    companion object {
        // ML Kit `com.google.mlkit.genai.common.FeatureStatus` integer constants.
        // Duplicated as plain Ints so this pure module never links ML Kit; the
        // boundary that DOES link it asserts these against the real symbols
        // (see GeminiNanoRewriterContract). Fail-closed default for any value
        // this map does not recognise.
        const val FEATURE_STATUS_UNAVAILABLE = 0
        const val FEATURE_STATUS_DOWNLOADABLE = 1
        const val FEATURE_STATUS_DOWNLOADING = 2
        const val FEATURE_STATUS_AVAILABLE = 3

        /** Map an ML Kit `FeatureStatus` integer to a flattened availability. */
        fun fromFeatureStatus(code: Int): GeminiNanoAvailability = when (code) {
            FEATURE_STATUS_AVAILABLE    -> AVAILABLE
            FEATURE_STATUS_DOWNLOADABLE -> DOWNLOADABLE
            FEATURE_STATUS_DOWNLOADING  -> DOWNLOADING
            FEATURE_STATUS_UNAVAILABLE  -> DEVICE_NOT_ELIGIBLE
            else                        -> UNSPECIFIED_UNAVAILABLE
        }
    }
}

// MARK: - User preference (quad-state, stored on its own)

/**
 * The explicit opt-out / opt-in for the on-device route, mirroring the Build
 * 116 `LocalRewritePreference` contract on iOS.
 *
 * Quad-state on purpose. A plain `Boolean` cannot distinguish "the person
 * turned this off" from "nobody has ever touched it", and it cannot express
 * "on, and nothing may leave the device". Raw values are the persisted form.
 */
enum class GeminiRewritePreference(val id: String) {
    /** Never chosen. Resolves to ON exactly when the model is [GeminiNanoAvailability.AVAILABLE]. */
    UNSET("unset"),

    /** Explicitly on. */
    ON("on"),

    /** Explicitly off. Honoured even when the model is available. */
    OFF("off"),

    /**
     * Explicitly on, AND explicitly the only route the person permits. With
     * this chosen, NOTHING in the on-device Coach flow may reach the network —
     * not the initial rewrite, not a retry, not a fallback after the on-device
     * model declines. When the device cannot serve the request the person is
     * told, once, and their draft is left exactly as they typed it.
     */
    ONLY_ON_DEVICE("only_on_device");

    /** The effective switch for a given runtime availability. */
    fun resolved(availability: GeminiNanoAvailability): Boolean = when (this) {
        ON, ONLY_ON_DEVICE -> true
        OFF                -> false
        UNSET              -> availability.isAvailable
    }

    /** Whether the person has made an explicit choice. */
    val isExplicit: Boolean get() = this != UNSET

    /** Whether this choice forbids any provider that leaves the device. */
    val prohibitsNetwork: Boolean get() = this == ONLY_ON_DEVICE

    companion object {
        fun from(raw: String?): GeminiRewritePreference =
            entries.firstOrNull { it.id == raw } ?: UNSET

        /**
         * The preference after the Settings toggle is set to [enabled], given
         * the [current] one. Pure so the store's rule is JVM-testable without
         * Android. Turning it back on must NOT widen an existing on-device-only
         * choice into "the cloud is fine again".
         */
        fun afterSetEnabled(current: GeminiRewritePreference, enabled: Boolean): GeminiRewritePreference =
            when {
                !enabled                 -> OFF
                current == ONLY_ON_DEVICE -> ONLY_ON_DEVICE
                else                     -> ON
            }

        /** The preference after the on-device-only switch is set to [only]. */
        fun afterSetOnDeviceOnly(only: Boolean): GeminiRewritePreference =
            if (only) ONLY_ON_DEVICE else ON
    }
}

/**
 * Persistence for the on-device preference.
 *
 * Deliberately NOT a `FeatureFlag`. `FeatureFlags.update(from:)` REPLACES the
 * whole cached dictionary with whatever `/v1/features` returned, so any
 * user-set value there is only as durable as the next feature fetch. A privacy
 * preference must not evaporate on a network round trip, so it gets its own key
 * and is never written by the flag refresh path. Same reasoning as iOS's
 * `LocalRewritePreferenceStore`.
 *
 * The remote kill switch is a SEPARATE thing (a feature flag): it can force the
 * on-device route off for everyone, but it is not the person's own switch.
 */
object GeminiRewritePreferenceStore {
    const val KEY = "tc.geminiRewritePreference.v1"

    fun load(): GeminiRewritePreference =
        GeminiRewritePreference.from(SharedStore.getString(KEY))

    fun save(preference: GeminiRewritePreference) {
        SharedStore.putString(KEY, preference.id)
    }

    /**
     * The Settings toggle writes an explicit choice in both directions, so
     * turning it back on is a real [GeminiRewritePreference.ON] rather than a
     * return to [GeminiRewritePreference.UNSET]. Turning the outer switch off
     * and on again must NOT silently widen an existing on-device-only choice
     * into "the cloud is fine again", so that narrower choice survives it.
     */
    fun setEnabled(enabled: Boolean) {
        save(GeminiRewritePreference.afterSetEnabled(load(), enabled))
    }

    /** The on-device-only choice, written explicitly in both directions. */
    fun setOnDeviceOnly(only: Boolean) {
        save(GeminiRewritePreference.afterSetOnDeviceOnly(only))
    }
}

// MARK: - Refusal reasons

/**
 * Every way the on-device route can decline, as one closed vocabulary. Mirror
 * of iOS `LocalCoachUnavailableReason`, adapted to Gemini Nano / ML Kit.
 *
 * One reason per distinguishable cause: an ineligible device, an OS floor, a
 * model still downloading, a cancellation, a timeout, a guardrail refusal, and
 * an outright generation failure are told apart rather than flattened into a
 * single apology.
 */
enum class GeminiRewriteUnavailableReason(val reasonCode: String) {
    // Policy
    REMOTE_KILL_SWITCH("remote_kill_switch"),
    USER_TURNED_OFF("user_turned_off"),

    // Runtime availability
    UNSUPPORTED_OS("unsupported_os"),
    DEVICE_NOT_ELIGIBLE("device_not_eligible"),
    MODEL_DOWNLOADABLE("model_downloadable"),
    MODEL_DOWNLOADING("model_downloading"),
    MODEL_NOT_READY("model_not_ready"),

    // Input bounds
    EMPTY_DRAFT("empty_draft"),
    DRAFT_TOO_LONG("draft_too_long"),

    // Runtime failures
    CANCELLED("cancelled"),
    TIMED_OUT("timed_out"),
    DOWNLOAD_FAILED("download_failed"),
    GUARDRAIL("guardrail"),
    GENERATION_FAILED("generation_failed"),

    /**
     * The model produced an empty rewrite, or one that is not distinct from the
     * source draft. Distinct from [GENERATION_FAILED] because the engine
     * succeeded — it simply had nothing new to say — so "check your connection"
     * would be the wrong thing to tell the person.
     */
    NO_VALID_REWRITE("no_valid_rewrite"),

    // Axis policy
    SAFER_NEEDS_REVIEW("safer_needs_review"),
    TONE_NEEDS_CONNECTION("tone_needs_connection"),
    CUSTOM_STYLE_NEEDS_CONNECTION("custom_style_needs_connection");

    companion object {
        /**
         * Availability maps onto a refusal so a new availability case cannot
         * silently land on a wrong sentence.
         */
        fun fromAvailability(availability: GeminiNanoAvailability): GeminiRewriteUnavailableReason =
            when (availability) {
                GeminiNanoAvailability.AVAILABLE               -> GENERATION_FAILED
                GeminiNanoAvailability.DOWNLOADABLE            -> MODEL_DOWNLOADABLE
                GeminiNanoAvailability.DOWNLOADING             -> MODEL_DOWNLOADING
                GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE     -> DEVICE_NOT_ELIGIBLE
                GeminiNanoAvailability.UNSUPPORTED_OS          -> UNSUPPORTED_OS
                GeminiNanoAvailability.UNSPECIFIED_UNAVAILABLE -> MODEL_NOT_READY
            }
    }
}

// MARK: - The on-device engine seam

/**
 * The result of one on-device rewrite attempt. A rewrite either succeeds with a
 * distinct, non-empty string or fails with a named reason — the source draft is
 * NEVER returned as a success.
 */
sealed class OnDeviceRewriteOutcome {
    data class Success(val text: String) : OnDeviceRewriteOutcome()
    data class Failure(val reason: GeminiRewriteUnavailableReason) : OnDeviceRewriteOutcome()
}

/**
 * The abstraction the keyboard talks to. The production implementation
 * (`:ime` `GeminiNanoRewriter`) is the ONLY code that links ML Kit; tests and
 * the pure JVM verifier inject a fake, so the decision logic never needs a
 * device. Keeping this interface in `:shared` is what lets `CoachViewModel`
 * depend on the abstraction rather than on ML Kit directly.
 */
interface OnDeviceRewriteEngine {
    /** A status check only — reads no draft, sends nothing off the device. */
    suspend fun availability(): GeminiNanoAvailability

    /**
     * Explicitly download the model assets. Called ONLY in response to a direct
     * user action; never a background or speculative fetch. Returns the
     * availability observed after the attempt.
     */
    suspend fun download(): GeminiNanoAvailability

    /**
     * Produce one on-device rewrite of [text] for [axis], bounded by
     * [timeoutMs]. Cancellable via coroutine cancellation. Returns a
     * [OnDeviceRewriteOutcome.Failure] rather than throwing for every expected
     * decline (unavailable, timeout, guardrail, no distinct rewrite).
     */
    suspend fun rewrite(
        text: String,
        axis: com.tono.shared.models.RewriteAxis,
        timeoutMs: Long,
    ): OnDeviceRewriteOutcome

    /** Release engine resources. Safe to call more than once. */
    fun close()
}

/** A fixed-answer probe used by tests and the pure verifier. */
class StaticOnDeviceRewriteEngine(
    private val availability: GeminiNanoAvailability,
    private val outcome: OnDeviceRewriteOutcome =
        OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.GENERATION_FAILED),
) : OnDeviceRewriteEngine {
    var rewriteCalls = 0; private set
    var downloadCalls = 0; private set

    override suspend fun availability(): GeminiNanoAvailability = availability
    override suspend fun download(): GeminiNanoAvailability { downloadCalls++; return availability }
    override suspend fun rewrite(
        text: String,
        axis: com.tono.shared.models.RewriteAxis,
        timeoutMs: Long,
    ): OnDeviceRewriteOutcome { rewriteCalls++; return outcome }
    override fun close() {}
}
