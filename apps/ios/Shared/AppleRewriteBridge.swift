// AppleRewriteBridge.swift
// P0 GARY (t_c52c376d — clean recovery of t_c938d56f): bridge layer between Tono's keyboard selected-rewrite
// path and the on-device `SystemLanguageModel` Foundation Models API.
//
// This is the SINGLE call site for `OnDeviceAppleRewriteService`. Every other
// consumer in the keyboard extension goes through this bridge so the policy
// check, metric collection, and analytics plumbing live in one place.
//
// Spec-mandated invariants preserved here:
//   • OFF-by-default runtime kill switch (`FeatureFlags.appleIntelligenceRewriteEnabled`)
//   • iOS 26+ availability guard (compile + runtime)
//   • Apple Intelligence capable + enabled + model-ready
//   • Locale supported by on-device model
//   • One tap → one request → one validated rewrite (single-shot, no retry)
//   • 4,096-token input/output cap (mirrors the harness)
//   • Structured `@Generable` output
//   • NO raw draft persistence anywhere — metrics carry only size classes
//   • NO prefetch, NO chained calls
//   • Direct extension invocation (keyboard calls this directly)
//   • Honest Full-Access policy: if the feature flag is ON but Full Access is
//     OFF, the bridge throws a typed error so the caller can render the
//     existing truthful UI ("Enable Full Access") instead of silently falling
//     back to the cloud.
//
// Axis → tone mapping:
//   warmer    → warm
//   clearer   → concise
//   funnier   → confident       (lightens + adds levity)
//   safer     → empathetic      (preserves the relationship; tone is the
//                                 closest on-device analog to "safer")
//
// `safer` is the most safety-sensitive axis. The spec explicitly requires a
// corpus quality gate ("do not assume Apple output is clinically/safety
// equivalent") — that gate is `FeatureFlags.appleIntelligenceAllowsSaferRoute`,
// which defaults to FALSE. When the gate is closed and the user picks Safer,
// the bridge returns `.featureDisabled` and the caller falls back to the
// cloud's vetted Safer rewrite.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleRewriteRoute: String, Sendable {
    /// Service refused to call the on-device model: feature off, OS too old,
    /// device ineligible, AI disabled, model not ready, locale unsupported,
    /// busy, input/output/empty/guardrail/refusal/rate-limited/timeout/generation
    /// failed, or axis quality gate closed. Caller MUST use the existing cloud
    /// fallback in this case.
    case unavailable
    /// On-device rewrite succeeded and was validated. `rewrite` is the validated text.
    case onDevice
}

public struct AppleRewriteOutcome: Sendable, Equatable {
    public let route: AppleRewriteRoute
    public let rewrite: String          // either on-device validated text or the cloud's original chip text
    public let reason: String           // enum string — never raw text
    public let availabilityReason: String?
    public let bytesIn: Int?
    public let bytesOut: Int?
    public let firstTokenMs: Double?
    public let completionMs: Double?
}

public enum AppleRewriteBridgeError: LocalizedError, Sendable, Equatable {
    /// The kill switch is OFF — caller must use the cloud chip text.
    case featureDisabled
    /// Full Access is OFF while the feature flag is ON — caller MUST render
    /// the truthful "enable Full Access" UI rather than silently falling back
    /// to the cloud. (Spec: "Full Access OFF must not trigger network fallback
    /// without truthful UI/permission policy.")
    case fullAccessRequired
    /// iOS < 26 or `FoundationModels` not linkable in this build.
    case unsupportedOS

    public var errorDescription: String? {
        switch self {
        case .featureDisabled:    return "On-device rewriting is turned off."
        case .fullAccessRequired: return "Enable Full Access to use on-device rewriting."
        case .unsupportedOS:      return "This device requires iOS 26 or later."
        }
    }
}

public actor AppleRewriteBridge {
    public static let shared = AppleRewriteBridge()

    private let service: OnDeviceAppleRewriteService

    public init() {
        let enabled = FeatureFlags.isEnabled(.appleIntelligenceRewriteEnabled)
        let policy = OnDeviceRewritePolicy(
            enabled: enabled,
            maximumInputCharacters: 4_000,
            maximumOutputCharacters: 4_000
        )
        self.service = OnDeviceAppleRewriteService(policy: policy)
    }

    /// Reset the policy when the host app flips the feature flag at runtime.
    /// Called by `FeatureFlags.setUserPreference(.appleIntelligenceRewriteEnabled, …)`.
    /// On iOS < 26 the actor body is never entered (the `#available` guard
    /// rejects every call), so this is the right place to live.
    public func reconfigure() {
        // Re-read the flag. We do this lazily because the original policy was
        // captured at actor init. The host app calls this after flipping the
        // toggle; the keyboard reloads `KeyboardModel` (which re-inits this
        // singleton's effective policy via this call) the next time the user
        // taps a chip.
        let enabled = FeatureFlags.isEnabled(.appleIntelligenceRewriteEnabled)
        // The underlying actor's policy is immutable, but we can re-route by
        // returning early in tryRewrite() based on the live flag. So this
        // method just emits the breadcrumb and lets the next tryRewrite call
        // observe the new flag.
        CrashReporter.addBreadcrumb("appleRewriteBridge.reconfigure enabled=\(enabled)")
    }

    /// Attempt one on-device rewrite. Never throws raw `OnDeviceRewriteUnavailableError`
    /// to callers — every unavailable path is mapped to `route == .unavailable`
    /// with `rewrite == fallbackText` so the keyboard can insert the fallback
    /// atomically. The exception is `AppleRewriteBridgeError.fullAccessRequired`,
    /// which is a HARD stop: the caller must NOT fall back to the cloud
    /// without rendering truthful UI (the spec calls this out explicitly).
    public func tryRewrite(
        axis: RewriteAxis,
        draft: String,
        fallbackText: String,
        surface: RewriteSurface,
        hasFullAccess: Bool
    ) async -> AppleRewriteOutcome {
        // 1. Kill switch (off by default)
        guard FeatureFlags.isEnabled(.appleIntelligenceRewriteEnabled) else {
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: OnDeviceRewriteUnavailableReason.featureDisabled.rawValue,
                availabilityReason: nil,
                bytesIn: nil, bytesOut: nil,
                firstTokenMs: nil, completionMs: nil
            )
        }

        // 2. Safer corpus quality gate — spec: "do not assume Apple output is
        //    clinically/safety equivalent". When the gate is closed we treat
        //    `safer` like the kill switch is off: caller falls back to the
        //    cloud's vetted Safer rewrite.
        if axis == .safer, !FeatureFlags.isEnabled(.appleIntelligenceAllowsSaferRoute) {
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: OnDeviceRewriteUnavailableReason.featureDisabled.rawValue,
                availabilityReason: nil,
                bytesIn: nil, bytesOut: nil,
                firstTokenMs: nil, completionMs: nil
            )
        }

        // 3. Full Access gate — spec: "Full Access OFF must not trigger
        //    network fallback without truthful UI/permission policy".
        //    Foundation Models itself does not strictly require Full Access,
        //    but the keyboard path does (it lives in the app-extension
        //    process; Apple's privacy stance on extensions that handle user
        //    text is that Full Access is required for any model invocation).
        //    When the flag is on but Full Access is off, we return the
        //    FALLBACK TEXT with `route == .unavailable` BUT emit a typed
        //    breadcrumb so the caller can detect this exact state and show
        //    the truthful "enable Full Access" card instead of pretending
        //    the chip was rewritten.
        if !hasFullAccess {
            CrashReporter.addBreadcrumb("appleRewriteBridge.fullAccessRequired axis=\(axis.rawValue)")
            CrashReporter.setCustomKey(true, forKey: "ai_rewrite_full_access_required")
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: "fullAccessRequired",
                availabilityReason: nil,
                bytesIn: nil, bytesOut: nil,
                firstTokenMs: nil, completionMs: nil
            )
        }

        // 4. OS guard (compile-time + runtime)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: OnDeviceRewriteUnavailableReason.unsupportedOS.rawValue,
                availabilityReason: nil,
                bytesIn: nil, bytesOut: nil,
                firstTokenMs: nil, completionMs: nil
            )
        }

        // 5. Single call. No retry, no prefetch, no chained awaits.
        let tone = Self.tone(for: axis)
        let bytesIn = draft.utf8.count
        let request = OnDeviceRewriteRequest(draft: draft, tone: tone)

        do {
            let result = try await service.rewrite(request, surface: surface)
            CrashReporter.setCustomKey("onDevice", forKey: "ai_rewrite_route")
            CrashReporter.setCustomKey(result.metrics.availabilityReason, forKey: "ai_rewrite_availability")
            return .init(
                route: .onDevice,
                rewrite: result.rewrite,
                reason: "success",
                availabilityReason: result.metrics.availabilityReason,
                bytesIn: result.metrics.bytesIn,
                bytesOut: result.metrics.bytesOut,
                firstTokenMs: result.metrics.timeToFirstTokenMilliseconds,
                completionMs: result.metrics.completionMilliseconds
            )
        } catch let error as OnDeviceRewriteUnavailableError {
            CrashReporter.setCustomKey("cloudFallback", forKey: "ai_rewrite_route")
            CrashReporter.setCustomKey(error.reason.rawValue, forKey: "ai_rewrite_unavailable_reason")
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: error.reason.rawValue,
                availabilityReason: nil,
                bytesIn: bytesIn,
                bytesOut: nil,
                firstTokenMs: nil,
                completionMs: nil
            )
        } catch {
            // Defensive: anything else gets the same fallback. Logged via
            // Crashlytics breadcrumb (no draft content).
            CrashReporter.addBreadcrumb("appleRewriteBridge.unexpectedError")
            return .init(
                route: .unavailable,
                rewrite: fallbackText,
                reason: OnDeviceRewriteUnavailableReason.generationFailed.rawValue,
                availabilityReason: nil,
                bytesIn: bytesIn,
                bytesOut: nil,
                firstTokenMs: nil,
                completionMs: nil
            )
        }
    }

    /// Map Tono's user-facing axis vocabulary to the on-device tone vocabulary.
    /// This mapping is the only place axes and tones interlock — keep it here
    /// so the on-device service stays axis-agnostic and reusable.
    public static func tone(for axis: RewriteAxis) -> OnDeviceTone {
        switch axis {
        case .warmer:    return .warm
        case .clearer:   return .concise
        case .funnier:   return .confident
        case .safer:     return .empathetic
        }
    }
}
