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

// Build 115 — the whole Coach answer in ONE request.
//
// The founder contract is "tapping Coach produces Warmer, Clearer and Funnier
// options, on the device, with no network". Three separate sessions would be
// three requests for one tap; one structured generation with three guided
// fields is one request that returns all three, which is both the contract and
// the faster path. Measured on the iOS 26.5 Simulator: ~10s for the trio via
// `respond`, versus ~60s for the same trio streamed snapshot-by-snapshot —
// streaming re-parses the whole partial object per token, so the non-streaming
// call is used here and `timeToFirstToken` is honestly absent from the metrics.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "Three rewrites of the sender's own message, one per tone")
private struct GuidedRewriteTrio {
    @Guide(description: "The same message rewritten to sound warmer and more considerate. Message text only.")
    var warmer: String
    @Guide(description: "The same message rewritten to be clearer and more direct. Message text only.")
    var clearer: String
    @Guide(description: "The same message rewritten with light, good-natured humour. Message text only.")
    var funnier: String
}

// The Safer variant, reachable ONLY when the corpus-quality gate is explicitly
// open. A separate type rather than an optional field, so a build with the gate
// closed cannot ask the model for a Safer rewrite at all.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "Four rewrites of the sender's own message, one per tone")
private struct GuidedRewriteQuartet {
    @Guide(description: "The same message rewritten to sound warmer and more considerate. Message text only.")
    var warmer: String
    @Guide(description: "The same message rewritten to be clearer and more direct. Message text only.")
    var clearer: String
    @Guide(description: "The same message rewritten with light, good-natured humour. Message text only.")
    var funnier: String
    @Guide(description: "The same message rewritten to lower the chance of causing offence, without changing what it asks for. Message text only.")
    var safer: String
}
#endif

// MARK: - Service (actor)

public actor OnDeviceAppleRewriteService {
    /// Build 115 — `var`, not `let`.
    ///
    /// This was the immutable-at-initialization defect. The policy was captured
    /// once, at actor init, and `AppleRewriteBridge.shared` is a process-lifetime
    /// singleton — so a service constructed while the flag was off kept refusing
    /// with `.featureDisabled` for the rest of the process even after the person
    /// turned the feature on, and `AppleRewriteBridge.reconfigure()` could only
    /// emit a breadcrumb about it. Callers now push the live policy in before
    /// every request, so a preference change takes effect on the very next tap
    /// without waiting for the extension process to be recycled.
    private var policy: OnDeviceRewritePolicy
    private var requestInFlight = false

    public init(policy: OnDeviceRewritePolicy) {
        self.policy = policy
    }

    /// Adopt a freshly-derived policy. Idempotent, and never interrupts work
    /// already in flight — the in-flight request finishes under the policy it
    /// started with, which is what "one tap, one request" means.
    public func updatePolicy(_ policy: OnDeviceRewritePolicy) {
        self.policy = policy
    }

    /// Test seam: the policy currently in force, so "a preference change is
    /// observed" is asserted against the real actor rather than inferred.
    public var effectivePolicy: OnDeviceRewritePolicy { policy }

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

    // MARK: - Build 115 · availability probe + one-request rewrite set

    /// Report what the on-device model says about itself, WITHOUT generating.
    ///
    /// This is what makes "default ON only when runtime availability is
    /// available" honest: the keyboard asks the model, per tap, rather than
    /// remembering a stored answer that a Settings change, an OS update or an
    /// asset download could have invalidated.
    public func probeAvailability(locale: Locale) -> LocalRewriteAvailability {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return .unsupportedOS }
        #if canImport(FoundationModels)
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .available : .unsupportedLocale
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unspecifiedUnavailable
        }
        #else
        return .unsupportedOS
        #endif
    }

    /// ONE request → the whole validated option set.
    ///
    /// Every guard the single-rewrite path applies is applied here, in the same
    /// order, plus the two the set path adds: an extension memory pre-flight,
    /// and cooperative cancellation between the model call and the validation
    /// step so a superseded tap cannot deliver.
    ///
    /// Throws `LocalCoachFailure` and nothing else. No cloud fallback decision
    /// is taken at this layer — the caller owns routing.
    public func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
        guard policy.enabled else { throw LocalCoachFailure(.remoteKillSwitch) }
        guard !requestInFlight else { throw LocalCoachFailure(.busy) }
        guard !request.axes.isEmpty else { throw LocalCoachFailure(.noValidRewrite) }
        let trimmed = request.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalCoachFailure(.emptyDraft) }
        guard request.draft.count <= policy.maximumInputCharacters else {
            throw LocalCoachFailure(.draftTooLong)
        }
        guard LocalCoachMemoryBudget.hasHeadroom(residentBytes: OnDeviceMemoryProbe.residentBytes())
        else { throw LocalCoachFailure(.memoryPressure) }
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else {
            throw LocalCoachFailure(.unsupportedOS)
        }

        requestInFlight = true
        defer { requestInFlight = false }
        return try await performRewriteSet(request)
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func performRewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
        #if canImport(FoundationModels)
        let started = ContinuousClock.now
        let availability = probeAvailability(locale: request.locale)
        guard availability.isAvailable else {
            throw LocalCoachFailure(LocalCoachUnavailableReason(availability: availability))
        }
        try checkCancellation()

        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        // Framing the sender explicitly is load-bearing, not decoration. Without
        // it the model reads the draft as a message TO it and answers the
        // message instead of rewriting it — observed directly while measuring
        // this path on the iOS 26.5 Simulator.
        let session = LanguageModelSession(model: model, instructions: Instructions("""
            You rewrite a message that the user is about to send to someone else.
            The user is the sender. Keep the user as the speaker: never answer \
            the message, never reply to it, and never change who is talking.
            Preserve the user's meaning, intent, facts, names, links and language.
            Do not add commentary, labels, quotation marks, markdown or new facts.
            Return only the rewritten message for each tone.
            """))
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: Self.maximumResponseTokens(for: request.axes.count)
        )
        let prompt = Prompt("Message to rewrite: \(request.draft)")
        let wantsSafer = request.axes.contains(.safer)

        var peak = OnDeviceMemoryProbe.residentBytes()
        do {
            var raw: [(axis: LocalCoachAxis, text: String)] = []
            if wantsSafer {
                let response = try await session.respond(
                    to: prompt, generating: GuidedRewriteQuartet.self,
                    includeSchemaInPrompt: true, options: options
                )
                let content = response.content
                raw = [
                    (.warmer, content.warmer), (.clearer, content.clearer),
                    (.funnier, content.funnier), (.safer, content.safer),
                ]
            } else {
                let response = try await session.respond(
                    to: prompt, generating: GuidedRewriteTrio.self,
                    includeSchemaInPrompt: true, options: options
                )
                let content = response.content
                raw = [
                    (.warmer, content.warmer), (.clearer, content.clearer),
                    (.funnier, content.funnier),
                ]
            }
            peak = Self.higher(peak, OnDeviceMemoryProbe.residentBytes())
            try checkCancellation()

            // Only the tones that were asked for, in the order they were asked
            // for. A model that filled a field nobody requested contributes
            // nothing to the answer.
            let requested = raw.filter { request.axes.contains($0.axis) }
            guard let validated = LocalCoachValidator.validateSet(
                requested,
                draft: request.draft,
                maximumCharacters: policy.maximumOutputCharacters
            ) else { throw LocalCoachFailure(.noValidRewrite) }

            return LocalCoachSetResult(
                options: validated,
                metrics: LocalCoachMetrics(
                    availabilityReason: availability.rawValue,
                    requestedAxisCount: request.axes.count,
                    validatedOptionCount: validated.count,
                    bytesIn: request.draft.utf8.count,
                    bytesOut: validated.reduce(0) { $0 + $1.text.utf8.count },
                    completionMilliseconds: milliseconds(since: started),
                    peakFootprintBytes: peak
                )
            )
        } catch let known as LocalCoachFailure {
            throw known
        } catch is CancellationError {
            throw LocalCoachFailure(.cancelled)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw LocalCoachFailure(.draftTooLong)
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw LocalCoachFailure(.guardrail)
        } catch LanguageModelSession.GenerationError.refusal {
            throw LocalCoachFailure(.refusal)
        } catch LanguageModelSession.GenerationError.rateLimited {
            throw LocalCoachFailure(.modelNotReady)
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            throw LocalCoachFailure(.unsupportedLocale)
        } catch {
            throw LocalCoachFailure(.generationFailed)
        }
        #else
        throw LocalCoachFailure(.unsupportedOS)
        #endif
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw LocalCoachFailure(.cancelled) }
    }

    private static func higher(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// Bounded output, scaled to how many tones were asked for. Generous enough
    /// for a long message rewritten four ways, small enough that a runaway
    /// generation ends rather than filling the extension's context.
    private static func maximumResponseTokens(for axisCount: Int) -> Int {
        min(1_024, 180 * max(axisCount, 1))
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
