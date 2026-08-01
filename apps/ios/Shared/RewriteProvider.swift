// RewriteProvider.swift
// Apple Intelligence readiness — the provider abstraction and the routing seam.
//
// WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT.
//
// This file factors the "which engine writes this rewrite" decision into one
// pure, total, unit-testable place: given an axis and the runtime facts about
// each engine, it returns a single ordered plan — one primary provider, then a
// fallback chain that is tried strictly one at a time. It is Foundation-only:
// no FoundationModels, no AppIntents, no UIKit, no network. Every input
// combination yields a decision and the decision never reads ambient state, so
// the whole matrix is testable on a machine with no device and no model.
//
// It does NOT rewire the live keyboard. The shipping keyboard routes through
// `LocalCoachRoutePolicy` (base three tones on-device) + `AppleRewriteBridge`,
// and that path is untouched. This router is a NARROWER, independently-adoptable
// seam that names the three provider families explicitly — Apple on-device,
// future Apple Private Cloud Compute, and the proven Tono backend — so a caller
// can adopt Apple Intelligence one axis at a time with the privacy and
// fail-closed rules written down rather than implied. `LocalCoachRoutePolicy`
// remains the authority the keyboard uses today; this generalizes it.
//
// THE THREE RULES THE PRODUCT OWNER STATED, ENCODED HERE:
//   • Safer stays on the proven backend route unless the corpus-quality gate is
//     explicitly open (`saferCorpusGateOpen`). On-device output is not assumed
//     safety-equivalent to the reviewed Safer route.
//   • Funnier is the low-risk Apple on-device spike: it is the default (and only
//     default) axis permitted to LEAD with the on-device model, because a missed
//     joke is recoverable in a way a mis-softened sensitive message is not.
//   • No fan-out: exactly one primary is attempted; fallbacks run only on
//     failure, one after another. The plan is a sequence, never a parallel set.

import Foundation

// MARK: - Provider identity

/// The three engine families a Tono rewrite can be produced by.
///
/// Raw values are stable (persisted in metrics / breadcrumbs), so do not rename
/// them. Informal marketing names for specific models are never encoded here —
/// a provider is a *family*, and the concrete model it resolves to is the
/// engine's own business.
public enum RewriteProviderKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// Apple Foundation Models running entirely on the device. Nothing leaves.
    case appleOnDevice
    /// Apple Private Cloud Compute — Apple's privacy-hardened server tier. The
    /// text is transmitted off the device (to Apple), so for the on-device-only
    /// promise this counts as leaving the device.
    case applePrivateCloudCompute
    /// Tono's own authenticated backend proxy (the current cloud route, which
    /// itself routes to the vetted provider server-side). Text leaves the device.
    case tonoBackend

    public var displayName: String {
        switch self {
        case .appleOnDevice:            return "On this device"
        case .applePrivateCloudCompute: return "Apple Private Cloud Compute"
        case .tonoBackend:              return "Tono"
        }
    }

    /// Whether using this provider transmits the user's text off the device.
    ///
    /// The single most privacy-load-bearing property in the file. Apple Private
    /// Cloud Compute is private, but it is NOT on-device — the text is sent to
    /// Apple's servers — so it returns `true` here alongside the backend. The
    /// on-device-only promise is about the device boundary, not about which
    /// operator receives the text, and conflating "private cloud" with "on
    /// device" is exactly the mistake that would silently break that promise.
    public var leavesDevice: Bool {
        switch self {
        case .appleOnDevice:            return false
        case .applePrivateCloudCompute: return true
        case .tonoBackend:              return true
        }
    }

    /// Whether this provider is an Apple Intelligence surface (on-device or PCC).
    public var isAppleIntelligence: Bool {
        switch self {
        case .appleOnDevice, .applePrivateCloudCompute: return true
        case .tonoBackend:                              return false
        }
    }
}

// MARK: - The route plan (a sequence, never a fan-out)

/// One primary provider plus an ordered fallback chain.
///
/// The whole point of the shape is that it CANNOT express a fan-out. There is
/// exactly one primary; `fallbacks` are attempted strictly in order and only
/// after the one before failed. `ordered` is the try-sequence, and it is always
/// duplicate-free.
public struct RewriteRoutePlan: Equatable, Sendable {
    public let primary: RewriteProviderKind
    public let fallbacks: [RewriteProviderKind]

    public init(primary: RewriteProviderKind, fallbacks: [RewriteProviderKind] = []) {
        self.primary = primary
        // Defensive: strip the primary and any duplicate from the tail so the
        // ordered sequence is always distinct, whatever a caller passes.
        var seen: Set<RewriteProviderKind> = [primary]
        self.fallbacks = fallbacks.filter { seen.insert($0).inserted }
    }

    /// The providers to attempt, in order, one at a time.
    public var ordered: [RewriteProviderKind] { [primary] + fallbacks }
}

/// The decision. Either a plan, or a terminal refusal that must NOT be turned
/// into a request (the person asked that nothing leave the device, or there is
/// no reachable engine).
public enum RewriteRoutingDecision: Equatable, Sendable {
    case route(RewriteRoutePlan)
    case terminal(LocalCoachUnavailableReason)

    /// Convenience for tests / callers: the primary provider if this is a route.
    public var primaryProvider: RewriteProviderKind? {
        if case .route(let plan) = self { return plan.primary }
        return nil
    }

    /// Convenience: the full try-sequence, or `[]` for a terminal decision.
    public var orderedProviders: [RewriteProviderKind] {
        if case .route(let plan) = self { return plan.ordered }
        return []
    }
}

// MARK: - The router

/// The single authority for "which provider, and in what fallback order".
///
/// Pure and total. The only configuration is which axes are allowed to lead
/// with the on-device Apple model — the spike set — and it defaults to Funnier
/// alone.
public struct RewriteProviderRouter: Sendable {

    /// Axes permitted to LEAD with the on-device Apple model.
    ///
    /// Default `[.funnier]`: the conservative spike. The live keyboard already
    /// produces Warmer/Clearer/Funnier on-device via `LocalCoachRoutePolicy`;
    /// this router starts narrower on purpose, so adopting the provider seam
    /// does not silently widen which tones lead with an unvetted engine. Widen
    /// this set only when an axis has earned it.
    public let appleOnDeviceSpikeAxes: Set<LocalCoachAxis>

    public init(appleOnDeviceSpikeAxes: Set<LocalCoachAxis> = [.funnier]) {
        self.appleOnDeviceSpikeAxes = appleOnDeviceSpikeAxes
    }

    /// Decide the provider plan for one request.
    ///
    /// - Parameters mirror `LocalCoachRoutePolicy.decide` so the two cannot
    ///   disagree about the meaning of an input:
    ///   - requestedAxis: the tone the person asked for (a `RewriteAxis` /
    ///     `LocalCoachAxis` raw value, or "custom").
    ///   - remoteKillSwitchAllows: the operator kill switch
    ///     (`appleIntelligenceRewriteEnabled`). False forces Apple off for all.
    ///   - preference: the person's own tri/quad-state choice, including
    ///     `.onlyOnDevice`, which forbids ANY provider that leaves the device.
    ///   - onDeviceAvailability: what the on-device model reports about itself.
    ///   - pccAvailability: what the PCC seam reports. Fail-closed by default.
    ///   - saferCorpusGateOpen: whether Safer may be produced by an Apple model.
    ///   - connectivityKnownAbsent: transport has PROVED there is no network, so
    ///     any provider that leaves the device is unreachable right now.
    public func decide(
        requestedAxis: String,
        remoteKillSwitchAllows: Bool,
        preference: LocalRewritePreference,
        onDeviceAvailability: LocalRewriteAvailability,
        pccAvailability: PCCAvailability,
        saferCorpusGateOpen: Bool,
        connectivityKnownAbsent: Bool
    ) -> RewriteRoutingDecision {
        let axis = requestedAxis.lowercased()
        let known = LocalCoachAxis(rawValue: axis)

        // Whether an Apple engine may serve THIS axis at all (independent of
        // which Apple engine). Safer needs the corpus gate; every other axis
        // must be in the spike set; an unknown axis (e.g. "custom") is never an
        // Apple axis here — the backend owns it.
        let appleMayServeAxis: Bool = {
            guard let known else { return false }
            if known == .safer { return saferCorpusGateOpen }
            return appleOnDeviceSpikeAxes.contains(known)
        }()

        // On-device eligibility: kill switch on, not opted out, preference
        // resolves ON against the REAL availability, availability actually
        // available, and the axis is Apple-servable.
        let onDeviceEligible =
            remoteKillSwitchAllows &&
            preference != .off &&
            preference.resolved(availability: onDeviceAvailability) &&
            onDeviceAvailability.isAvailable &&
            appleMayServeAxis

        // PCC eligibility: kill switch on, the seam proves it available, and the
        // axis is Apple-servable. Preference `.off` also suppresses it (an Apple
        // opt-out is an opt-out of the Apple engines, both of them).
        let pccEligible =
            remoteKillSwitchAllows &&
            preference != .off &&
            pccAvailability.isAvailable &&
            appleMayServeAxis

        // Build the priority chain, MOST PRIVATE FIRST. The backend is always a
        // candidate here — it is the proven route and the only one that can
        // serve Safer (closed gate), Custom, and any non-spike axis.
        var chain: [RewriteProviderKind] = []
        if onDeviceEligible { chain.append(.appleOnDevice) }
        if pccEligible { chain.append(.applePrivateCloudCompute) }
        chain.append(.tonoBackend)

        // The on-device-only promise: drop every provider that leaves the
        // device. PCC leaves the device, so it goes too.
        if preference.prohibitsNetwork {
            chain.removeAll { $0.leavesDevice }
        }
        // No network right now: anything that leaves the device is unreachable.
        if connectivityKnownAbsent {
            chain.removeAll { $0.leavesDevice }
        }

        guard let primary = chain.first else {
            return .terminal(terminalReason(
                axis: known,
                remoteKillSwitchAllows: remoteKillSwitchAllows,
                preference: preference,
                onDeviceAvailability: onDeviceAvailability
            ))
        }
        return .route(RewriteRoutePlan(primary: primary, fallbacks: Array(chain.dropFirst())))
    }

    /// Why nothing could serve the request. Reached only when the chain is empty
    /// — i.e. the person forbade the network (or it is known absent) and no
    /// Apple engine could serve the axis on the device.
    private func terminalReason(
        axis: LocalCoachAxis?,
        remoteKillSwitchAllows: Bool,
        preference: LocalRewritePreference,
        onDeviceAvailability: LocalRewriteAvailability
    ) -> LocalCoachUnavailableReason {
        if !remoteKillSwitchAllows { return .remoteKillSwitch }
        if preference == .off { return .userTurnedOff }
        if !onDeviceAvailability.isAvailable {
            return LocalCoachUnavailableReason(availability: onDeviceAvailability)
        }
        // The device CAN run a model, but not for this axis, and the network is
        // gone: name the axis-specific reason rather than a generic failure.
        switch axis {
        case .safer: return .saferNeedsReview
        case nil:    return .customStyleNeedsConnection
        default:     return .toneNeedsConnection
        }
    }
}
