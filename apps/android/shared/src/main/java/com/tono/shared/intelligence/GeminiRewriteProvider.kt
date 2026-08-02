package com.tono.shared.intelligence

import com.tono.shared.models.RewriteAxis

// Google-intelligence readiness — the provider abstraction and the routing seam.
//
// Android mirror of ios/Shared/RewriteProvider.swift (the Apple Intelligence
// seam). Same job, same invariants, Google's engines instead of Apple's.
//
// WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT.
//
// This file factors the "which engine writes this rewrite" decision into one
// pure, total, unit-testable place: given an axis and the runtime facts about
// each engine, it returns a single ordered plan — one primary provider, then a
// fallback chain that is tried strictly one at a time. It is pure Kotlin: no
// ML Kit, no AppFunctions, no Android framework, no network. Every input
// combination yields a decision and the decision never reads ambient state, so
// the whole matrix is testable on a plain JVM with no device and no AICore.
//
// It does NOT rewire the live keyboard on its own. `CoachViewModel` adopts it
// for exactly one explicit, additive gesture (on-device Funnier), and the
// existing Coach/Read/backend flow is unchanged when the on-device engine is
// unavailable — which is the default on any device without AICore/Gemini Nano.
//
// THE THREE RULES THE PRODUCT OWNER STATED, ENCODED HERE:
//   • Safer stays on the proven backend route unless the corpus-quality gate is
//     explicitly open (`saferCorpusGateOpen`). On-device output is not assumed
//     safety-equivalent to the reviewed Safer route.
//   • Funnier is the low-risk on-device spike: it is the default (and only
//     default) axis permitted to LEAD with Gemini Nano, because a missed joke
//     is recoverable in a way a mis-softened sensitive message is not.
//   • No fan-out: exactly one primary is attempted; fallbacks run only on
//     failure, one after another, and only after an explicit user action. The
//     plan is a sequence, never a parallel set.
//
// ASYMMETRY VS iOS, STATED HONESTLY. The Apple seam names three families
// (on-device, Private Cloud Compute, backend). Google's on-device engine is
// Gemini Nano via AICore; there is NO developer-addressable privacy-hardened
// Google *cloud* rewrite tier that Tono integrates, so there is no PCC analog
// here. Tono's own backend IS the cloud route. Two families, not three — and
// inventing a third would be exactly the fabricated capability this seam
// refuses to encode.

// MARK: - Provider identity

/**
 * The two engine families a Tono rewrite can be produced by on Android.
 *
 * Raw values are stable (persisted in metrics / breadcrumbs), so do not rename
 * them. A provider is a *family*; the concrete model it resolves to (e.g. which
 * Gemini Nano build AICore serves) is the engine's own business and is never
 * encoded here.
 */
enum class RewriteProviderKind(val id: String) {
    /** Gemini Nano running entirely on the device via AICore. Nothing leaves. */
    GEMINI_NANO_ON_DEVICE("gemini_nano_on_device"),

    /**
     * Tono's own authenticated backend proxy (the current cloud route, which
     * itself routes to the vetted provider server-side). Text leaves the device.
     */
    TONO_BACKEND("tono_backend");

    val displayName: String
        get() = when (this) {
            GEMINI_NANO_ON_DEVICE -> "On this device"
            TONO_BACKEND          -> "Tono"
        }

    /**
     * Whether using this provider transmits the user's text off the device.
     *
     * The single most privacy-load-bearing property in the file. Gemini Nano
     * runs on-device, so it does not leave; the backend does. The
     * on-device-only promise is about the device boundary.
     */
    val leavesDevice: Boolean
        get() = when (this) {
            GEMINI_NANO_ON_DEVICE -> false
            TONO_BACKEND          -> true
        }

    /** Whether this provider is a Google on-device intelligence surface. */
    val isGoogleIntelligence: Boolean
        get() = this == GEMINI_NANO_ON_DEVICE

    val reasonCode: String get() = id
}

// MARK: - The route plan (a sequence, never a fan-out)

/**
 * One primary provider plus an ordered fallback chain.
 *
 * The whole point of the shape is that it CANNOT express a fan-out. There is
 * exactly one primary; [fallbacks] are attempted strictly in order and only
 * after the one before failed. [ordered] is the try-sequence, always
 * duplicate-free.
 */
data class RewriteRoutePlan(
    val primary: RewriteProviderKind,
    val fallbacks: List<RewriteProviderKind> = emptyList(),
) {
    init {
        // Defensive: keep the constructed value distinct even if a caller passes
        // a fallback that repeats the primary or itself. `ordered` is derived
        // below from the normalized fields.
    }

    /** The providers to attempt, in order, one at a time; always distinct. */
    val ordered: List<RewriteProviderKind>
        get() {
            val seen = LinkedHashSet<RewriteProviderKind>()
            seen.add(primary)
            fallbacks.forEach { seen.add(it) }
            return seen.toList()
        }
}

/**
 * The decision. Either a plan, or a terminal refusal that must NOT be turned
 * into a request (the person asked that nothing leave the device, or there is
 * no reachable engine).
 */
sealed class RewriteRoutingDecision {
    data class Route(val plan: RewriteRoutePlan) : RewriteRoutingDecision()
    data class Terminal(val reason: GeminiRewriteUnavailableReason) : RewriteRoutingDecision()

    /** The primary provider if this is a route, else null. */
    val primaryProvider: RewriteProviderKind?
        get() = (this as? Route)?.plan?.primary

    /** The full try-sequence, or `[]` for a terminal decision. */
    val orderedProviders: List<RewriteProviderKind>
        get() = (this as? Route)?.plan?.ordered ?: emptyList()
}

// MARK: - The router

/**
 * The single authority for "which provider, and in what fallback order".
 *
 * Pure and total. The only configuration is which axes may LEAD with the
 * on-device Gemini Nano model — the spike set — and it defaults to Funnier
 * alone. Mirrors `RewriteProviderRouter` on iOS one input at a time so the two
 * platforms cannot disagree about the meaning of a request.
 */
class GeminiRewriteRouter(
    /**
     * Axes permitted to LEAD with the on-device Gemini Nano model.
     *
     * Default `{FUNNIER}`: the conservative spike. Widen only when an axis has
     * earned it. Safer is never in here (it needs the corpus gate instead), and
     * an unknown/custom axis is never a Google axis — the backend owns it.
     */
    val onDeviceSpikeAxes: Set<RewriteAxis> = setOf(RewriteAxis.FUNNIER),
) {

    /**
     * Decide the provider plan for one request.
     *
     * @param requestedAxis the tone the person asked for (a [RewriteAxis] raw
     *   value, or any other string such as "custom").
     * @param remoteKillSwitchAllows the operator kill switch. False forces the
     *   on-device engine off for everyone.
     * @param preference the person's own quad-state choice, including
     *   [GeminiRewritePreference.ONLY_ON_DEVICE], which forbids ANY provider
     *   that leaves the device.
     * @param onDeviceAvailability what the on-device model reports about itself.
     * @param saferCorpusGateOpen whether Safer may be produced on-device.
     * @param connectivityKnownAbsent transport has PROVED there is no network,
     *   so any provider that leaves the device is unreachable right now.
     */
    fun decide(
        requestedAxis: String,
        remoteKillSwitchAllows: Boolean,
        preference: GeminiRewritePreference,
        onDeviceAvailability: GeminiNanoAvailability,
        saferCorpusGateOpen: Boolean,
        connectivityKnownAbsent: Boolean,
    ): RewriteRoutingDecision {
        val axis = requestedAxis.lowercase()
        val known = RewriteAxis.from(axis)

        // Whether a Google on-device engine may serve THIS axis at all. Safer
        // needs the corpus gate; every other known axis must be in the spike
        // set; an unknown axis (e.g. "custom") is never a Google axis here.
        val googleMayServeAxis: Boolean = when {
            known == null            -> false
            known == RewriteAxis.SAFER -> saferCorpusGateOpen
            else                     -> onDeviceSpikeAxes.contains(known)
        }

        // On-device eligibility: kill switch on, not opted out, preference
        // resolves ON against the REAL availability, the model is actually
        // available, and the axis is Google-servable.
        val onDeviceEligible =
            remoteKillSwitchAllows &&
            preference != GeminiRewritePreference.OFF &&
            preference.resolved(onDeviceAvailability) &&
            onDeviceAvailability.isAvailable &&
            googleMayServeAxis

        // Build the priority chain, MOST PRIVATE FIRST. The backend is always a
        // candidate — it is the proven route and the only one that can serve
        // Safer (closed gate), custom, and any non-spike axis.
        val chain = mutableListOf<RewriteProviderKind>()
        if (onDeviceEligible) chain.add(RewriteProviderKind.GEMINI_NANO_ON_DEVICE)
        chain.add(RewriteProviderKind.TONO_BACKEND)

        // The on-device-only promise: drop every provider that leaves the
        // device. No network right now does the same.
        if (preference.prohibitsNetwork || connectivityKnownAbsent) {
            chain.removeAll { it.leavesDevice }
        }

        val primary = chain.firstOrNull()
            ?: return RewriteRoutingDecision.Terminal(
                terminalReason(known, remoteKillSwitchAllows, preference, onDeviceAvailability)
            )
        return RewriteRoutingDecision.Route(
            RewriteRoutePlan(primary = primary, fallbacks = chain.drop(1))
        )
    }

    /**
     * Why nothing could serve the request. Reached only when the chain is empty
     * — i.e. the person forbade the network (or it is known absent) and no
     * Google engine could serve the axis on the device.
     */
    private fun terminalReason(
        axis: RewriteAxis?,
        remoteKillSwitchAllows: Boolean,
        preference: GeminiRewritePreference,
        onDeviceAvailability: GeminiNanoAvailability,
    ): GeminiRewriteUnavailableReason {
        if (!remoteKillSwitchAllows) return GeminiRewriteUnavailableReason.REMOTE_KILL_SWITCH
        if (preference == GeminiRewritePreference.OFF) return GeminiRewriteUnavailableReason.USER_TURNED_OFF
        if (!onDeviceAvailability.isAvailable) {
            return GeminiRewriteUnavailableReason.fromAvailability(onDeviceAvailability)
        }
        // The device CAN run a model, but not for this axis, and the network is
        // gone: name the axis-specific reason rather than a generic failure.
        return when (axis) {
            RewriteAxis.SAFER -> GeminiRewriteUnavailableReason.SAFER_NEEDS_REVIEW
            null              -> GeminiRewriteUnavailableReason.CUSTOM_STYLE_NEEDS_CONNECTION
            else              -> GeminiRewriteUnavailableReason.TONE_NEEDS_CONNECTION
        }
    }
}
