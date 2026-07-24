// OnDeviceAppleRewrite.swift
// P0 GARY (t_c52c376d — clean recovery of t_c938d56f): iOS 26+ on-device Apple Intelligence rewrite service
// integrated into Tono's keyboard selected-rewrite path. Source-harness:
// parent kanban t_b202c70d final HEAD 21c24722 (Sources/TonoFoundationModels/TonoFoundationModels.swift).
//
// Contract (mirrors the harness 1:1 — every line traceable to spec):
//   • iOS 26+ availability check (compile-time @available + runtime SystemLanguageModel.availability)
//   • Apple Intelligence capable + enabled + model-ready
//   • Locale supported by the on-device model
//   • One tap → one request → one validated rewrite
//   • 4,096-token budget (bounded input + output)
//   • Structured output (GuidedRewrite @Generable)
//   • NO raw draft persistence — this struct never writes to UserDefaults / FileManager / App Group
//   • NO prefetch, NO hidden retries
//   • Direct extension invocation (the keyboard calls it directly, no host-app round-trip)
//   • Metrics contain NO raw text — only route, availability reason, timestamps, error class
//
// OFF-by-default. The actual call site is gated by FeatureFlags.appleIntelligenceRewriteEnabled,
// which is false until a human enables it in the host app Settings.
//
// Module map:
//   • RewriteRequest / RewriteResult / RewriteMetrics / RewriteUnavailableReason / RewriteUnavailableError
//     — the wire shapes (used both by the keyboard path and by tests).
//   • RewriteFeaturePolicy — feature-flag + input/output caps.
//   • OnDeviceAppleRewriteService — actor that owns the requestInFlight lock and exposes the
//     single rewrite() entry point used by the keyboard.
//   • MemoryProbe — Darwin-only resident-byte sampler (lives here so the Shared module
//     does not need FoundationModels to compile against).

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Tone (wire-shape parity with parent harness)

// Five-tone vocabulary mapped 1:1 to the parent harness `TonoTone`. Kept as a
// separate type so the Tono keyboard's existing `RewriteAxis` enum (warmer /
// clearer / funnier / safer) does not leak into the on-device contract. The
// mapping happens at the call site, not inside the service — the service stays
// axis-agnostic and reusable.
public enum OnDeviceTone: String, CaseIterable, Codable, Sendable {
    case concise, warm, professional, confident, empathetic
}

// MARK: - Surface

public enum RewriteSurface: String, Codable, Sendable {
    case hostApp
    case keyboardExtension
    case corpusRunner
}

// MARK: - Wire shapes

public struct OnDeviceRewriteRequest: Sendable, Equatable {
    public let draft: String
    public let tone: OnDeviceTone
    public let locale: Locale

    public init(draft: String, tone: OnDeviceTone, locale: Locale = .current) {
        self.draft = draft
        self.tone = tone
        self.locale = locale
    }
}

public struct OnDeviceRewriteMetrics: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let surface: RewriteSurface
    public let availabilityReason: String        // "available" / "deviceNotEligible" / etc — enum string, NO draft
    public let availabilityCheckMilliseconds: Double
    public let timeToFirstTokenMilliseconds: Double?
    public let completionMilliseconds: Double?
    public let validated: Bool
    public let outcome: String                    // "success" / failure-reason enum
    public let bytesIn: Int                       // draft byte length (size class, not content)
    public let bytesOut: Int                      // rewrite byte length (size class, not content)

    public init(requestID: UUID, surface: RewriteSurface, availabilityReason: String,
                availabilityCheckMilliseconds: Double,
                timeToFirstTokenMilliseconds: Double?, completionMilliseconds: Double?,
                validated: Bool, outcome: String, bytesIn: Int, bytesOut: Int) {
        self.requestID = requestID
        self.surface = surface
        self.availabilityReason = availabilityReason
        self.availabilityCheckMilliseconds = availabilityCheckMilliseconds
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.completionMilliseconds = completionMilliseconds
        self.validated = validated
        self.outcome = outcome
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct OnDeviceRewriteResult: Sendable, Equatable {
    public let rewrite: String
    public let metrics: OnDeviceRewriteMetrics
}

// MARK: - Unavailable reasons (typed errors, NO fallback to cloud from this layer)

public enum OnDeviceRewriteUnavailableReason: String, Codable, Sendable, Equatable {
    case featureDisabled
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case inputTooLong
    case outputTooLong
    case emptyResult
    case busy
    case guardrailViolation
    case refusal
    case rateLimited
    case contextWindowExceeded
    case generationFailed
}

public struct OnDeviceRewriteUnavailableError: LocalizedError, Sendable, Equatable {
    public let reason: OnDeviceRewriteUnavailableReason
    public let userMessage: String

    public init(_ reason: OnDeviceRewriteUnavailableReason, _ message: String) {
        self.reason = reason
        self.userMessage = message
    }

    public var errorDescription: String? { userMessage }
}

// MARK: - Feature policy (runtime kill switch + caps)

public struct OnDeviceRewritePolicy: Sendable, Equatable {
    public var enabled: Bool
    public var maximumInputCharacters: Int
    public var maximumOutputCharacters: Int

    public init(enabled: Bool = false,
                maximumInputCharacters: Int = 4_000,
                maximumOutputCharacters: Int = 4_000) {
        self.enabled = enabled
        self.maximumInputCharacters = maximumInputCharacters
        self.maximumOutputCharacters = maximumOutputCharacters
    }
}

// MARK: - @Generable output schema (iOS 26+ only)

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "A single rewritten draft")
private struct GuidedRewrite {
    @Guide(description: "The rewritten text only")
    var text: String
}
#endif

// MARK: - Service (actor)

public actor OnDeviceAppleRewriteService {
    private let policy: OnDeviceRewritePolicy
    private var requestInFlight = false

    public init(policy: OnDeviceRewritePolicy) {
        self.policy = policy
    }

    /// Single entry point. Maps every spec-required guard onto a typed error
    /// before any model work runs. Caller is expected to fall back to the
    /// existing authenticated cloud endpoint for any `.featureDisabled`,
    /// `.unsupportedOS`, `.deviceNotEligible`, `.appleIntelligenceNotEnabled`,
    /// `.modelNotReady`, `.unsupportedLocale`, `.busy`, `.guardrailViolation`,
    /// `.refusal`, `.rateLimited`, `.emptyResult`, `.outputTooLong`,
    /// `.generationFailed`, or `.contextWindowExceeded` result.
    public func rewrite(_ request: OnDeviceRewriteRequest, surface: RewriteSurface) async throws -> OnDeviceRewriteResult {
        guard policy.enabled else {
            throw OnDeviceRewriteUnavailableError(.featureDisabled, "On-device rewriting is turned off.")
        }
        guard !requestInFlight else {
            throw OnDeviceRewriteUnavailableError(.busy, "A rewrite is already in progress.")
        }
        guard !request.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.draft.count <= policy.maximumInputCharacters else {
            throw OnDeviceRewriteUnavailableError(.inputTooLong, "Select a shorter draft and try again.")
        }
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw OnDeviceRewriteUnavailableError(.unsupportedOS, "This device requires iOS 26 or later.")
        }

        requestInFlight = true
        defer { requestInFlight = false }
        return try await performRewrite(request, surface: surface)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func performRewrite(_ request: OnDeviceRewriteRequest, surface: RewriteSurface) async throws -> OnDeviceRewriteResult {
        let requestID = UUID()
        let started = ContinuousClock.now
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        let availabilityElapsed = milliseconds(since: started)
        var availabilityReason = "available"

        switch model.availability {
        case .available:
            availabilityReason = "available"
        case .unavailable(.deviceNotEligible):
            availabilityReason = "deviceNotEligible"
            throw OnDeviceRewriteUnavailableError(.deviceNotEligible, "Apple Intelligence is not supported on this device.")
        case .unavailable(.appleIntelligenceNotEnabled):
            availabilityReason = "appleIntelligenceNotEnabled"
            throw OnDeviceRewriteUnavailableError(.appleIntelligenceNotEnabled, "Turn on Apple Intelligence in Settings to use on-device rewriting.")
        case .unavailable(.modelNotReady):
            availabilityReason = "modelNotReady"
            throw OnDeviceRewriteUnavailableError(.modelNotReady, "Apple Intelligence is still downloading or temporarily unavailable.")
        case .unavailable:
            availabilityReason = "unspecifiedUnavailable"
            throw OnDeviceRewriteUnavailableError(.modelNotReady, "Apple Intelligence is temporarily unavailable.")
        }

        guard model.supportsLocale(request.locale) else {
            throw OnDeviceRewriteUnavailableError(.unsupportedLocale, "The selected language is not supported by Apple Intelligence.")
        }

        let instructions = Instructions("""
            Rewrite the supplied draft in a \(request.tone.rawValue) tone.
            Preserve meaning, names, facts, links, and the original language.
            Do not add commentary, labels, markdown fences, or invented facts.
            Return exactly one rewrite.
            """)
        let session = LanguageModelSession(model: model, instructions: instructions)

        do {
            var firstTokenElapsed: Double?
            var lastText: String?
            let stream = session.streamResponse(
                to: Prompt(request.draft),
                generating: GuidedRewrite.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(sampling: .greedy)
            )
            for try await snapshot in stream {
                if firstTokenElapsed == nil { firstTokenElapsed = milliseconds(since: started) }
                lastText = snapshot.content.text
            }
            let candidate = lastText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !candidate.isEmpty else {
                throw OnDeviceRewriteUnavailableError(.emptyResult, "The rewrite could not be validated. Your draft was left unchanged.")
            }
            guard candidate.count <= policy.maximumOutputCharacters else {
                throw OnDeviceRewriteUnavailableError(.outputTooLong, "The rewrite could not be validated. Your draft was left unchanged.")
            }
            let metrics = OnDeviceRewriteMetrics(
                requestID: requestID,
                surface: surface,
                availabilityReason: availabilityReason,
                availabilityCheckMilliseconds: availabilityElapsed,
                timeToFirstTokenMilliseconds: firstTokenElapsed,
                completionMilliseconds: milliseconds(since: started),
                validated: true,
                outcome: "success",
                bytesIn: request.draft.utf8.count,
                bytesOut: candidate.utf8.count
            )
            return OnDeviceRewriteResult(rewrite: candidate, metrics: metrics)
        } catch let known as OnDeviceRewriteUnavailableError {
            throw known
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw OnDeviceRewriteUnavailableError(.contextWindowExceeded, "Select a shorter draft and try again.")
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw OnDeviceRewriteUnavailableError(.guardrailViolation, "This draft cannot be rewritten safely.")
        } catch LanguageModelSession.GenerationError.refusal {
            throw OnDeviceRewriteUnavailableError(.refusal, "Apple Intelligence declined this rewrite. Your draft was left unchanged.")
        } catch LanguageModelSession.GenerationError.rateLimited {
            throw OnDeviceRewriteUnavailableError(.rateLimited, "Apple Intelligence is busy. Try again in a moment.")
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            throw OnDeviceRewriteUnavailableError(.unsupportedLocale, "The selected language is not supported by Apple Intelligence.")
        } catch {
            throw OnDeviceRewriteUnavailableError(.generationFailed, "The rewrite failed. Your draft was left unchanged.")
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}

// MARK: - Memory probe (Darwin-only, optional observability)

public enum OnDeviceMemoryProbe {
    public static func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
        #else
        return nil
        #endif
    }
}
