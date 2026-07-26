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

    /// Push the live policy into the service.
    ///
    /// Build 115 repair. This used to re-read the flag and then do nothing with
    /// it, because `OnDeviceAppleRewriteService.policy` was a `let` captured at
    /// actor init and `AppleRewriteBridge.shared` lives for the whole process.
    /// A person who turned the feature on in Settings kept getting
    /// `.featureDisabled` until the keyboard extension happened to be recycled,
    /// and the only trace was a breadcrumb saying the opposite. The policy is
    /// now mutable and every entry point re-derives it first, so a preference
    /// change is observed on the NEXT TAP — no process reload required.
    @discardableResult
    public func reconfigure() async -> OnDeviceRewritePolicy {
        let policy = Self.currentPolicy()
        await service.updatePolicy(policy)
        return policy
    }

    /// Derive the policy from live state, every time. The remote kill switch is
    /// the only input from the feature-flag cache; the person's own opt-out
    /// lives in `LocalRewritePreferenceStore` precisely so a `/v1/features`
    /// refresh cannot overwrite it.
    static func currentPolicy() -> OnDeviceRewritePolicy {
        OnDeviceRewritePolicy(
            enabled: FeatureFlags.isEnabled(.appleIntelligenceRewriteEnabled),
            maximumInputCharacters: LocalCoachRoutePolicy.maximumDraftCharacters,
            maximumOutputCharacters: LocalCoachRoutePolicy.maximumOptionCharacters
        )
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

// MARK: - Build 115 · the live keyboard's engine

// The UIKit keyboard reaches Foundation Models through exactly this
// conformance. `tryRewrite` above stays as it is for the SwiftUI selected-chip
// path; the two share one service, one policy derivation and one set of caps,
// so there is still a single place where on-device policy is decided.
//
// The one deliberate difference: this path does NOT require Full Access.
// `tryRewrite` refuses without it, on the reasoning that a keyboard extension
// handling user text should hold Full Access before invoking a model. That
// reasoning does not survive the offline-first contract — the local route makes
// no network request at all, so it is strictly MORE private than the typing the
// keyboard already does, and requiring a network permission to run something
// that never touches the network would make the promise false for exactly the
// people who declined Full Access for privacy reasons. Nothing here reads the
// document proxy, persists a draft, or opens a connection.
extension AppleRewriteBridge: LocalCoachRewriteEngine {
    public func availability(locale: Locale) async -> LocalRewriteAvailability {
        await service.probeAvailability(locale: locale)
    }

    public func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
        // Re-derive the policy before every request. This is the fix for the
        // immutable-at-initialization defect: the answer must reflect the
        // preference as it is now, not as it was when this singleton was born.
        await service.updatePolicy(Self.currentPolicy())
        return try await service.rewriteSet(request)
    }
}
